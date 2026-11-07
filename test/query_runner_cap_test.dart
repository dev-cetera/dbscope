// Contract: QueryRunner.runSql picks how its row limit is enforced. A plain read
// stops at the limit on the server. Anything that may write reads to the end,
// because stopping it would leave it unfinished. Neither needs anything sent
// ahead of the statement. It reports what the backend says about truncation
// rather than cutting the rows again itself.

import 'package:dbscope/db/executor.dart';
import 'package:dbscope/query/runner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_executor.dart';

void main() {
  test('a plain read stops at the limit, with nothing sent ahead of it', () async {
    final executor = FakeDbExecutor();
    await QueryRunner(executor).runSql('SELECT * FROM t');
    final call = executor.calls.single;
    expect(call.rowCap?.mode, RowCapMode.stopAtLimit);
    expect(call.rowCap?.maxRows, QueryRunner.maxRows);
  });

  test('a write reads to the end', () async {
    final executor = FakeDbExecutor();
    await QueryRunner(executor).runSql('DELETE FROM t RETURNING *');
    expect(executor.calls.single.rowCap?.mode, RowCapMode.readAndDrop);
  });

  test('a fenced read is capped inside the fence', () async {
    final executor = FakeDbExecutor();
    await QueryRunner(executor).runSql('SELECT * FROM t', readOnly: true);
    final order = executor.calls.map((call) => call.sql).toList();
    expect(order.indexOf('BEGIN TRANSACTION READ ONLY'), lessThan(order.indexOf('SELECT * FROM t')));
    final capped = executor.calls.singleWhere((call) => call.rowCap != null);
    expect(capped.rowCap?.mode, RowCapMode.stopAtLimit);
  });

  test('truncated comes from the backend', () async {
    final executor = FakeDbExecutor();
    executor.enqueue(
      const DbResult(
        columns: [DbColumn(name: 'a')],
        rows: [
          [1],
        ],
        truncated: true,
      ),
    );
    final result = await QueryRunner(executor).runSql('SELECT a FROM t');
    expect(result.truncated, isTrue);
    expect(result.data.rows, hasLength(1));
  });
}
