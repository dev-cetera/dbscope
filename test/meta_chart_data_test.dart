// Contract: how a chart's result rows become plotted points.
//
// - A time or numeric x plots in ascending order whatever order the SQL
//   returned it in (named queries are often sorted newest-first for
//   reading); equal x values keep the query's order.
// - Any other x (labels, categories) keeps the query's own order.
// - A row-scoped chart whose SQL binds a masked value is refused before any
//   SQL runs.
// - A table histogram that read a full sample page says it is a sample.

import 'package:dbscope/db/executor.dart';
import 'package:dbscope/meta/action_binding.dart';
import 'package:dbscope/meta/chart_sql.dart';
import 'package:dbscope/meta/charts/chart_data.dart';
import 'package:dbscope/meta/masked_value.dart';
import 'package:dbscope/meta/meta_models.dart';
import 'package:dbscope/meta/selector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_executor.dart';

ChartSpec _chart() => ChartSpec(
  id: 'c',
  target: Selector.tryParse('*')!,
  label: 'C',
  type: ChartType.line,
  source: const ChartSqlSource('SELECT x, n FROM t'),
  x: 'x',
  y: const [ChartMeasure(column: 'n')],
);

Future<ChartData> _run(List<List<Object?>> rows) {
  final executor = FakeDbExecutor()
    // The fence's two open-transaction probes, BEGIN and statement_timeout.
    ..enqueue(const DbResult(columns: [], rows: []))
    ..enqueue(const DbResult(columns: [], rows: []))
    ..enqueue(const DbResult(columns: [], rows: []))
    ..enqueue(const DbResult(columns: [], rows: []))
    ..enqueue(
      DbResult(
        columns: const [
          DbColumn(name: 'x'),
          DbColumn(name: 'n'),
        ],
        rows: rows,
      ),
    );
  return runChart(_chart(), executor: executor);
}

void main() {
  test('time x plots ascending even when the query sorts descending', () async {
    final data = await _run([
      [DateTime.utc(2026, 10, 3), 3],
      [DateTime.utc(2026, 10), 1],
      [DateTime.utc(2026, 10, 2), 2],
    ]);
    expect(data.series.single.values, [1.0, 2.0, 3.0]);
  });

  test('categorical x keeps the query order', () async {
    final data = await _run([
      ['zeta', 1],
      ['alpha', 2],
    ]);
    expect(data.xLabels, ['zeta', 'alpha']);
  });

  test('a row chart refuses a masked bound value without running SQL', () async {
    final executor = FakeDbExecutor();
    final chart = ChartSpec(
      id: 'c',
      target: Selector.tryParse('*')!,
      label: 'C',
      type: ChartType.line,
      source: const ChartSqlSource('SELECT x, n FROM t WHERE s = @row_status'),
      x: 'x',
      y: const [ChartMeasure(column: 'n')],
    );
    await expectLater(
      runChart(
        chart,
        executor: executor,
        row: const BindingContext(row: {'status': MaskedValue.instance}),
      ),
      throwsA(isA<ChartRunError>()),
    );
    expect(executor.calls, isEmpty);
  });

  group('histogram sample label', () {
    Future<ChartData> run(int rows) {
      final executor = FakeDbExecutor()
        ..enqueue(
          const DbResult(
            columns: [DbColumn(name: 'column_name')],
            rows: [
              ['n', 'integer', 'int4', false, null, false, false, 'b', 'pg_catalog'],
            ],
          ),
        )
        ..enqueue(const DbResult(columns: [], rows: []))
        ..enqueue(const DbResult(columns: [], rows: []))
        ..enqueue(const DbResult(columns: [], rows: []))
        ..enqueue(const DbResult(columns: [], rows: []))
        ..enqueue(
          DbResult(
            columns: const [DbColumn(name: 'x')],
            rows: [
              for (var i = 0; i < rows; i++) [i],
            ],
          ),
        );
      final chart = ChartSpec(
        id: 'h',
        target: Selector.tryParse('*')!,
        label: 'H',
        type: ChartType.histogram,
        source: const ChartTableSource('public', 't'),
        x: 'n',
      );
      return runChart(chart, executor: executor);
    }

    test('a full sample page is flagged as a sample', () async {
      final data = await run(kHistogramSampleRows);
      expect(data.sampledRows, kHistogramSampleRows);
    });

    test('a short result is not flagged', () async {
      final data = await run(50);
      expect(data.sampledRows, isNull);
    });
  });
}
