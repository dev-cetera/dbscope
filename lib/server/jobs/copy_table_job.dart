// CopyTableJob — streams rows from a source table to a target table.
// Mode:
// 'append' – just INSERT.
// 'truncate' – TRUNCATE target before insert (in the same transaction).
//
// Constraints:
// - Both endpoints must be the built-in postgres kind. Cross-kind copy
// (e.g. an HTTP-mediated backend -> local postgres) would need a
// non-transactional path; out of scope for now.
// - Target schema/table must already exist.
// - Column list comes from source; target must have matching columns
// (by name). Extra target columns get their default.
//
// Progress events: {phase, processed, total?} on bus topic
// job.progress:<jobId>
//
// Reading the source: a server-side cursor (DECLARE, then FETCH in a loop)
// inside one REPEATABLE READ READ ONLY transaction, on a connection the job
// opens for itself. That gives one consistent snapshot for the whole copy —
// no rows skipped or duplicated across batches, which LIMIT/OFFSET without
// ORDER BY could not promise — streams instead of materialising, works for
// tables with no primary key, and costs O(n) instead of OFFSET's O(n²). The
// dedicated connection is what makes a long transaction safe: on the shared
// one it would make every other server-side query throw (the driver refuses
// queries while a transaction is open) and could deadlock two jobs.

import 'dart:math' as math;

import 'package:postgres/postgres.dart' as pg;

import '../../db/executor.dart';
import '../../db/postgres_executor.dart';
import '../../rpc/envelope.dart';
import '../../util/sql_quote.dart';
import 'job.dart';

class CopyTableJob implements JobHandler {
  /// Upper bound on rows per FETCH / INSERT round-trip.
  static const batchSize = 500;

  /// Postgres caps one statement at 65 535 bind parameters (the wire
  /// protocol's parameter count is an Int16).
  static const maxBindParams = 65535;

  /// Name of the server-side cursor. It lives only inside the copy's own
  /// transaction on its own connection, so a fixed name cannot collide.
  static const cursorName = 'dbscope_copy_table';

  /// Rows per FETCH and per multi-row INSERT for a table of [columnCount]
  /// columns: [batchSize], shrunk so one INSERT never binds more than
  /// [maxBindParams] values. Always at least 1.
  static int rowsPerBatch(int columnCount) => math.max(
    1,
    math.min(batchSize, maxBindParams ~/ math.max(1, columnCount)),
  );

  @override
  String get kind => 'copy_table';

  @override
  Future<Map<String, Object?>> run(JobContext jobContext) async {
    final jobParams = jobContext.record.spec.params;
    final sourceId = jobParams['sourceConnectionId'] as String?;
    final targetId = jobParams['targetConnectionId'] as String?;
    final sourceSchema = jobParams['sourceSchema'] as String?;
    final sourceTable = jobParams['sourceTable'] as String?;
    final targetSchema = (jobParams['targetSchema'] as String?) ?? sourceSchema;
    final targetTable = (jobParams['targetTable'] as String?) ?? sourceTable;
    final mode = (jobParams['mode'] as String?) ?? 'append';

    if (sourceId == null ||
        targetId == null ||
        sourceSchema == null ||
        sourceTable == null ||
        targetSchema == null ||
        targetTable == null) {
      throw const RpcError(
        'bad_params',
        'sourceConnectionId/targetConnectionId/sourceSchema/sourceTable required',
      );
    }
    if (sourceId == targetId && sourceSchema == targetSchema && sourceTable == targetTable) {
      throw const RpcError(
        'bad_params',
        'source and target are the same table',
      );
    }

    final sourceExecutor = await jobContext.connections.openDedicated(
      sourceId,
    );
    try {
      return await _copy(
        jobContext,
        source: _requirePostgres(sourceExecutor),
        target: _requirePostgres(await jobContext.connections.obtain(targetId)),
        sourceId: sourceId,
        targetId: targetId,
        sourceSchema: sourceSchema,
        sourceTable: sourceTable,
        targetSchema: targetSchema,
        targetTable: targetTable,
        mode: mode,
      );
    } finally {
      await sourceExecutor.close();
    }
  }

  Future<Map<String, Object?>> _copy(
    JobContext jobContext, {
    required pg.Connection source,
    required pg.Connection target,
    required String sourceId,
    required String targetId,
    required String sourceSchema,
    required String sourceTable,
    required String targetSchema,
    required String targetTable,
    required String mode,
  }) async {
    final qSource = quoteQualified(sourceSchema, sourceTable);
    final qTarget = quoteQualified(targetSchema, targetTable);

    jobContext.reportProgress({'phase': 'planning', 'processed': 0});

    // Discover source columns in ordinal order; this is the column set
    // we'll select and insert.
    final colResult = await source.execute(
      pg.Sql.named('''
 SELECT column_name
 FROM information_schema.columns
 WHERE table_schema = @schema AND table_name = @table
 ORDER BY ordinal_position
 '''),
      parameters: {'schema': sourceSchema, 'table': sourceTable},
    );
    final columns = [for (final row in colResult) row[0]! as String];
    if (columns.isEmpty) {
      throw RpcError('empty_schema', 'no columns for $qSource');
    }

    // Confirm target has all those columns (by name).
    final targetColumnResult = await target.execute(
      pg.Sql.named('''
 SELECT column_name
 FROM information_schema.columns
 WHERE table_schema = @schema AND table_name = @table
 '''),
      parameters: {'schema': targetSchema, 'table': targetTable},
    );
    final targetColumns = {
      for (final row in targetColumnResult) row[0]! as String,
    };
    if (targetColumns.isEmpty) {
      throw RpcError('missing_target', 'target $qTarget not found');
    }
    final missing = columns.where((column) => !targetColumns.contains(column)).toList();
    if (missing.isNotEmpty) {
      throw RpcError(
        'schema_mismatch',
        'target missing columns: ${missing.join(', ')}',
      );
    }

    var processed = 0;
    await target.runTx((transaction) async {
      if (mode == 'truncate') {
        jobContext.reportProgress({'phase': 'truncating', 'processed': 0});
        await transaction.execute('TRUNCATE $qTarget');
      }
      jobContext.reportProgress({'phase': 'copying', 'processed': 0});

      // Source is the inner transaction, so its snapshot ends before the
      // target commits; an error or cancellation rolls back both, which
      // also closes the cursor. Separate connections, so nesting can't
      // deadlock — even when source and target are the same profile.
      processed = await source.runTx(
        (snapshot) => copyRows(
          source: snapshot,
          target: transaction,
          qSource: qSource,
          qTarget: qTarget,
          columns: columns,
          isCancelled: () => jobContext.cancelled,
          onProgress: (copied) => jobContext.reportProgress({
            'phase': 'copying',
            'processed': copied,
          }),
        ),
        settings: pg.TransactionSettings(
          isolationLevel: pg.IsolationLevel.repeatableRead,
          accessMode: pg.AccessMode.readOnly,
        ),
      );
    });

    jobContext.bus.publish('schema.invalidated:$targetId', {
      'schema': targetSchema,
      'table': targetTable,
    });

    return {
      'processed': processed,
      'sourceConnectionId': sourceId,
      'targetConnectionId': targetId,
      'sourceTable': '$sourceSchema.$sourceTable',
      'targetTable': '$targetSchema.$targetTable',
    };
  }

  /// Streams every row of [qSource] (restricted to [columns], in that order)
  /// through a server-side cursor on [source] and inserts it into [qTarget]
  /// via [target], [rowsPerBatch] rows per round-trip. Returns rows copied.
  ///
  /// [source] must already be inside a transaction — Postgres only allows
  /// DECLARE in a transaction block, and the cursor dies with it.
  ///
  /// [isCancelled] is polled before every FETCH; when it returns true this
  /// throws `RpcError('cancelled')`. The cursor is CLOSEd explicitly only on
  /// success: on any error the enclosing transaction rolls back, which
  /// closes it, and a CLOSE sent into an aborted transaction would fail and
  /// mask the real error.
  static Future<int> copyRows({
    required pg.Session source,
    required pg.Session target,
    required String qSource,
    required String qTarget,
    required List<String> columns,
    required bool Function() isCancelled,
    required void Function(int processed) onProgress,
  }) async {
    final quotedColumns = columns.map(quoteIdent).join(', ');
    final cursor = quoteIdent(cursorName);
    final rowsPerFetch = rowsPerBatch(columns.length);

    await source.execute(
      'DECLARE $cursor NO SCROLL CURSOR FOR '
      'SELECT $quotedColumns FROM $qSource',
    );
    var processed = 0;
    while (true) {
      if (isCancelled()) {
        throw const RpcError('cancelled', 'job cancelled');
      }
      final batch = await source.execute(
        'FETCH FORWARD $rowsPerFetch FROM $cursor',
      );
      if (batch.isEmpty) break;
      final params = <Object?>[];
      final tuples = <String>[];
      for (final row in batch) {
        final placeholders = <String>[];
        for (var i = 0; i < columns.length; i++) {
          params.add(row[i]);
          placeholders.add('\$${params.length}');
        }
        tuples.add('(${placeholders.join(', ')})');
      }
      await target.execute(
        'INSERT INTO $qTarget ($quotedColumns) VALUES ${tuples.join(', ')}',
        parameters: params,
      );
      processed += batch.length;
      onProgress(processed);
      if (batch.length < rowsPerFetch) break;
    }
    await source.execute('CLOSE $cursor');
    return processed;
  }

  pg.Connection _requirePostgres(DbExecutor executor) {
    if (executor is! PostgresExecutor) {
      throw RpcError(
        'unsupported_backend',
        'copy_table requires postgres on both ends (got ${executor.kind})',
      );
    }
    return executor.raw;
  }
}
