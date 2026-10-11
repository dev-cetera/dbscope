// Contract: how a chart's result rows become plotted points.
//
// - A time or numeric x plots in ascending order whatever order the SQL
//   returned it in (named queries are often sorted newest-first for
//   reading); equal x values keep the query's order.
// - Any other x (labels, categories) keeps the query's own order.

import 'package:dbscope/db/executor.dart';
import 'package:dbscope/meta/charts/chart_data.dart';
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
  final exec = FakeDbExecutor()
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
  return runChart(_chart(), executor: exec);
}

void main() {
  test('time x plots ascending even when the query sorts descending', () async {
    final data = await _run([
      [DateTime.utc(2026, 10, 3), 3],
      [DateTime.utc(2026, 10, 1), 1],
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
}
