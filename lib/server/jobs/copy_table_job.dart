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

import 'package:postgres/postgres.dart' as pg;

import '../../db/executor.dart';
import '../../db/postgres_executor.dart';
import '../../rpc/envelope.dart';
import '../../util/sql_quote.dart';
import 'job.dart';

class CopyTableJob implements JobHandler {
  static const int batchSize = 500;

  @override
  String get kind => 'copy_table';

  @override
  Future<Map<String, Object?>> run(JobContext ctx) async {
    final p = ctx.record.spec.params;
    final sourceId = p['sourceConnectionId'] as String?;
    final targetId = p['targetConnectionId'] as String?;
    final sourceSchema = p['sourceSchema'] as String?;
    final sourceTable = p['sourceTable'] as String?;
    final targetSchema = (p['targetSchema'] as String?) ?? sourceSchema;
    final targetTable = (p['targetTable'] as String?) ?? sourceTable;
    final mode = (p['mode'] as String?) ?? 'append';

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
    if (sourceId == targetId &&
        sourceSchema == targetSchema &&
        sourceTable == targetTable) {
      throw const RpcError(
        'bad_params',
        'source and target are the same table',
      );
    }

    final source = _requirePostgres(await ctx.connections.obtain(sourceId));
    final target = _requirePostgres(await ctx.connections.obtain(targetId));

    final qSource = quoteQualified(sourceSchema, sourceTable);
    final qTarget = quoteQualified(targetSchema, targetTable);

    ctx.reportProgress({'phase': 'planning', 'processed': 0});

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
    final columns = [for (final row in colResult) row[0] as String];
    if (columns.isEmpty) {
      throw RpcError('empty_schema', 'no columns for $qSource');
    }

    // Confirm target has all those columns (by name).
    final tgtColResult = await target.execute(
      pg.Sql.named('''
 SELECT column_name
 FROM information_schema.columns
 WHERE table_schema = @schema AND table_name = @table
 '''),
      parameters: {'schema': targetSchema, 'table': targetTable},
    );
    final targetCols = {for (final row in tgtColResult) row[0] as String};
    if (targetCols.isEmpty) {
      throw RpcError('missing_target', 'target $qTarget not found');
    }
    final missing = columns.where((c) => !targetCols.contains(c)).toList();
    if (missing.isNotEmpty) {
      throw RpcError(
        'schema_mismatch',
        'target missing columns: ${missing.join(', ')}',
      );
    }

    final selectSql =
        'SELECT ${columns.map(quoteIdent).join(', ')} FROM $qSource';
    final insertCols = columns.map(quoteIdent).join(', ');

    var processed = 0;
    await target.runTx((tx) async {
      if (mode == 'truncate') {
        ctx.reportProgress({'phase': 'truncating', 'processed': 0});
        await tx.execute('TRUNCATE $qTarget');
      }
      ctx.reportProgress({'phase': 'copying', 'processed': 0});
      // Stream from source in pages of [batchSize].
      // Simplest: SELECT once into memory in chunks via OFFSET. For very
      // large tables this is suboptimal but matches Phase 3 scope; a
      // cursor-based stream is the obvious upgrade.
      var offset = 0;
      while (true) {
        if (ctx.cancelled) {
          throw const RpcError('cancelled', 'job cancelled');
        }
        final batch = await source.execute(
          pg.Sql('$selectSql LIMIT $batchSize OFFSET $offset'),
        );
        if (batch.isEmpty) break;
        final buffer = StringBuffer(
          'INSERT INTO $qTarget ($insertCols) VALUES ',
        );
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
        buffer.write(tuples.join(', '));
        await tx.execute(pg.Sql(buffer.toString()), parameters: params);
        processed += batch.length;
        ctx.reportProgress({'phase': 'copying', 'processed': processed});
        if (batch.length < batchSize) break;
        offset += batch.length;
      }
    });

    ctx.bus.publish('schema.invalidated:$targetId', {
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

  pg.Connection _requirePostgres(DbExecutor exec) {
    if (exec is! PostgresExecutor) {
      throw RpcError(
        'unsupported_backend',
        'copy_table requires postgres on both ends (got ${exec.kind})',
      );
    }
    return exec.raw;
  }
}
