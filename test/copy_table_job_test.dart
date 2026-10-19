// CopyTableJob.copyRows moves user data between databases. The contract
// worth guarding here:
// * The source is read through one server-side cursor (DECLARE ... NO
// SCROLL CURSOR, FETCH FORWARD n, CLOSE) — never LIMIT/OFFSET, which
// without ORDER BY can skip or duplicate rows across batches.
// * The loop stops on the first short (or empty) FETCH, and an empty
// table issues no INSERT.
// * One multi-row INSERT never binds more than Postgres's 65 535
// parameters: rowsPerBatch shrinks for wide tables, never below 1.
// * Values travel only as positional params; identifiers are quoted.
// * Cancellation is polled before every FETCH and throws
// RpcError('cancelled') without a CLOSE (the enclosing transaction's
// rollback closes the cursor).
//
// No live Postgres here: _FakeSession stands in for both the source
// transaction and the target transaction.

import 'package:dbscope/rpc/envelope.dart';
import 'package:dbscope/server/jobs/copy_table_job.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart' as pg;

import 'support/fake_executor.dart';

/// Records every statement; answers FETCH from [_rows] in order.
class _FakeSession implements pg.Session {
  _FakeSession({List<List<Object?>> rows = const []}) : _rows = [...rows];

  final List<List<Object?>> _rows;
  final List<ExecuteCall> calls = [];

  @override
  bool get isOpen => true;

  @override
  Future<void> get closed => Future<void>.value();

  @override
  Future<pg.Statement> prepare(Object query) =>
      throw UnimplementedError('prepare is not used by copyRows');

  @override
  Future<pg.Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    pg.QueryMode? queryMode,
    Duration? timeout,
  }) async {
    // copyRows sends plain-String SQL (identical to `pg.Sql(...)` on the
    // wire); a String keeps the text inspectable here.
    final sql = query as String;
    calls.add(ExecuteCall(sql, positional: parameters as List<Object?>?));
    final schema = pg.ResultSchema(const []);
    final fetch = RegExp(r'^FETCH FORWARD (\d+) FROM ').firstMatch(sql);
    if (fetch == null) {
      return pg.Result(rows: const [], affectedRows: 0, schema: schema);
    }
    final count = int.parse(fetch.group(1)!);
    final take = count < _rows.length ? count : _rows.length;
    final batch = _rows.sublist(0, take);
    _rows.removeRange(0, take);
    return pg.Result(
      rows: [
        for (final values in batch) pg.ResultRow(values: values, schema: schema),
      ],
      affectedRows: batch.length,
      schema: schema,
    );
  }
}

List<List<Object?>> _rowsOf(int count, int width) => [
  for (var r = 0; r < count; r++) [for (var c = 0; c < width; c++) 'r${r}c$c'],
];

void main() {
  group('rowsPerBatch', () {
    test('is 500 for ordinary tables', () {
      expect(CopyTableJob.rowsPerBatch(1), 500);
      expect(CopyTableJob.rowsPerBatch(131), 500);
    });

    test('shrinks so rows * columns stays within 65 535 params', () {
      for (final width in [132, 200, 1000, 1600]) {
        final rows = CopyTableJob.rowsPerBatch(width);
        expect(rows, lessThan(500));
        expect(rows * width, lessThanOrEqualTo(CopyTableJob.maxBindParams));
      }
      expect(CopyTableJob.rowsPerBatch(132), 65535 ~/ 132);
    });

    test('never drops below 1', () {
      expect(CopyTableJob.rowsPerBatch(70000), 1);
      expect(CopyTableJob.rowsPerBatch(0), 500);
    });
  });

  group('copyRows', () {
    Future<(_FakeSession, _FakeSession, int, List<int>)> run({
      required List<List<Object?>> rows,
      required List<String> columns,
    }) async {
      final source = _FakeSession(rows: rows);
      final target = _FakeSession();
      final progress = <int>[];
      final copied = await CopyTableJob.copyRows(
        source: source,
        target: target,
        qSource: '"src"."t"',
        qTarget: '"dst"."t"',
        columns: columns,
        isCancelled: () => false,
        onProgress: progress.add,
      );
      return (source, target, copied, progress);
    }

    test('declares a cursor, fetches until a short batch, then closes', () async {
      final (source, target, copied, progress) = await run(
        rows: _rowsOf(1200, 2),
        columns: ['id', 'na"me'],
      );
      expect(copied, 1200);
      expect(progress, [500, 1000, 1200]);
      expect(source.calls.map((c) => c.sql), [
        'DECLARE "dbscope_copy_table" NO SCROLL CURSOR FOR SELECT "id", "na""me" FROM "src"."t"',
        'FETCH FORWARD 500 FROM "dbscope_copy_table"',
        'FETCH FORWARD 500 FROM "dbscope_copy_table"',
        'FETCH FORWARD 500 FROM "dbscope_copy_table"',
        'CLOSE "dbscope_copy_table"',
      ]);
      expect(source.calls.any((c) => c.sql.contains('OFFSET')), isFalse);
      expect(target.calls, hasLength(3));
      expect(
        target.calls.first.sql,
        startsWith(r'INSERT INTO "dst"."t" ("id", "na""me") VALUES ($1, $2), '),
      );
      // Values are bound, never inlined.
      expect(target.calls.first.positional, hasLength(1000));
      expect(target.calls.first.positional!.first, 'r0c0');
      expect(target.calls.first.sql, isNot(contains('r0c0')));
      expect(target.calls.last.positional, hasLength(400));
      expect(target.calls.last.positional!.last, 'r1199c1');
    });

    test('an exact multiple of the batch ends on an empty FETCH', () async {
      final (source, target, copied, _) = await run(
        rows: _rowsOf(1000, 1),
        columns: ['id'],
      );
      expect(copied, 1000);
      expect(
        source.calls.where((c) => c.sql.startsWith('FETCH')),
        hasLength(3),
      );
      expect(target.calls, hasLength(2));
      expect(source.calls.last.sql, startsWith('CLOSE'));
    });

    test('an empty table issues no INSERT', () async {
      final (source, target, copied, progress) = await run(
        rows: const [],
        columns: ['id'],
      );
      expect(copied, 0);
      expect(progress, isEmpty);
      expect(target.calls, isEmpty);
      expect(source.calls.last.sql, startsWith('CLOSE'));
    });

    test('wide tables batch under the bind-parameter limit', () async {
      const width = 300;
      final columns = [for (var c = 0; c < width; c++) 'c$c'];
      final (_, target, copied, _) = await run(
        rows: _rowsOf(1000, width),
        columns: columns,
      );
      expect(copied, 1000);
      for (final call in target.calls) {
        expect(
          call.positional!.length,
          lessThanOrEqualTo(CopyTableJob.maxBindParams),
        );
      }
      expect(target.calls.first.positional, hasLength(218 * width));
    });

    test('cancellation stops before the next FETCH, without CLOSE', () async {
      final source = _FakeSession(rows: _rowsOf(1200, 1));
      final target = _FakeSession();
      var cancelled = false;
      await expectLater(
        CopyTableJob.copyRows(
          source: source,
          target: target,
          qSource: '"src"."t"',
          qTarget: '"dst"."t"',
          columns: ['id'],
          isCancelled: () => cancelled,
          onProgress: (_) => cancelled = true,
        ),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(
        source.calls.where((c) => c.sql.startsWith('FETCH')),
        hasLength(1),
      );
      expect(source.calls.any((c) => c.sql.startsWith('CLOSE')), isFalse);
      expect(target.calls, hasLength(1));
    });
  });
}
