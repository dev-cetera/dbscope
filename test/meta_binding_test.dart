// Contract: plan.md "action" placeholders and "chart" SQL.
//
// Binding:
// - `@name` placeholders bind as parameters; values never enter the SQL.
// - Placeholders inside strings, quoted identifiers, comments and
//   dollar-quoted bodies are left alone; `@>`/`@@` operators and the
//   driver's `@x:type` annotation survive.
// - `@rows_<col>` expands to one parameter per selected row.
// - A placeholder the context can't satisfy is reported as missing.
//
// Chart SQL:
// - identifiers are quoted, aggregates and buckets come from fixed lists;
// - a chart naming an unreadable column is refused.

import 'package:dbscope/meta/action_binding.dart';
import 'package:dbscope/meta/chart_sql.dart';
import 'package:dbscope/meta/meta_index.dart';
import 'package:dbscope/meta/meta_models.dart';
import 'package:dbscope/meta/meta_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bindSql', () {
    test('binds row, pk, cell, names and inputs as parameters', () {
      final bound = bindSql(
        'SELECT * FROM t WHERE a = @row_id AND b = @pk_id AND c = @cell '
        'AND d = @table AND e = @input_email',
        const BindingContext(
          table: 'users',
          row: {'id': 7},
          primaryKey: {'id': 7},
          cell: 'x',
          inputs: {'email': 'a@b.c'},
        ),
      );
      expect(bound.isComplete, isTrue);
      expect(bound.named, {
        'row_id': 7,
        'pk_id': 7,
        'cell': 'x',
        'table': 'users',
        'input_email': 'a@b.c',
      });
      expect(bound.sql, contains('@row_id'));
    });

    test(
      'ignores strings, identifiers, comments, dollar quotes, operators',
      () {
        const sql = r'''
SELECT '@row_x', "@row_y", data @> '{}', a @@ b -- @row_z
/* @row_w */ , $$ @row_v $$, @row_id:int8''';
        expect(findPlaceholders(sql), ['row_id']);
      },
    );

    test('expands a selection into IN parameters', () {
      final bound = bindSql(
        'DELETE FROM t WHERE id IN (@rows_id)',
        const BindingContext(
          selection: [
            {'id': 1},
            {'id': 2},
            {'id': 3},
          ],
        ),
      );
      expect(
        bound.sql,
        'DELETE FROM t WHERE id IN (@rows_id_0, @rows_id_1, @rows_id_2)',
      );
      expect(bound.named, {'rows_id_0': 1, 'rows_id_1': 2, 'rows_id_2': 3});
    });

    test('reports placeholders the context cannot satisfy', () {
      final bound = bindSql(
        'SELECT @row_missing, @mystery, @rows_id',
        const BindingContext(row: {'id': 1}),
      );
      expect(bound.missing, ['row_missing', 'mystery', 'rows_id']);
    });

    test('renderTemplate encodes substituted values only', () {
      final url = renderTemplate(
        'https://x.test/u/{row.id}?q={cell}',
        const BindingContext(row: {'id': 'a b'}, cell: 'c&d'),
        encode: Uri.encodeComponent,
      );
      expect(url, 'https://x.test/u/a%20b?q=c%26d');
    });

    test('when conditions match row values', () {
      final index = MetaIndex.build(
        mergeMetaSources([
          FileSource.parseText('''
meta:
  - { id: a, target: public.t, kind: action, label: L, scope: row, run: query, sql: "SELECT 1", when: { row.kind: [A, B] } }
'''),
        ]),
      );
      final action = index.actions.single;
      expect(
        whenHolds(action, const BindingContext(row: {'kind': 'A'})),
        isTrue,
      );
      expect(
        whenHolds(action, const BindingContext(row: {'kind': 'C'})),
        isFalse,
      );
      expect(whenHolds(action, const BindingContext()), isFalse);
    });
  });

  group('buildTableChartSql', () {
    ChartSpec chart(String yaml) => MetaIndex.build(
      mergeMetaSources([
        FileSource.parseText('meta:\n  - $yaml'),
      ]),
    ).charts.single;

    test('time series with series and range, postgres', () {
      final c = chart(
        '{ id: c, target: public.accounts, kind: chart, type: line, '
        'x: created_at, bucket: day, series: source, range: last_7_days, '
        'y: [{ agg: count }] }',
      );
      final sql = buildTableChartSql(
        chart: c,
        schema: 'public',
        table: 'accounts',
        readableColumns: {'created_at', 'source'},
        dialect: SqlDialect.postgres,
      );
      expect(
        sql.sql,
        'SELECT date_trunc(\'day\', "created_at") AS x, "source" AS series, '
        'count(*) AS y0 FROM "public"."accounts" '
        "WHERE \"created_at\" >= now() - interval '168 hours' "
        'GROUP BY date_trunc(\'day\', "created_at"), "source" '
        'ORDER BY x LIMIT 500',
      );
      expect(sql.hasSeries, isTrue);
    });

    test('sqlite buckets use strftime', () {
      final c = chart(
        '{ id: c, target: main.t, kind: chart, type: bar, x: at, bucket: month }',
      );
      final sql = buildTableChartSql(
        chart: c,
        schema: 'main',
        table: 't',
        readableColumns: {'at'},
        dialect: SqlDialect.sqlite,
      );
      expect(sql.sql, contains("strftime('%Y-%m', CASE WHEN typeof(\"at\")"));
      expect(sql.sql, contains("'unixepoch'"));
    });

    test('refuses an unreadable column', () {
      final c = chart(
        '{ id: c, target: public.users, kind: chart, type: pie, x: email }',
      );
      expect(
        () => buildTableChartSql(
          chart: c,
          schema: 'public',
          table: 'users',
          readableColumns: {'name'},
          dialect: SqlDialect.postgres,
        ),
        throwsA(isA<ChartSqlError>()),
      );
    });

    test('stat and histogram shapes', () {
      final stat = chart(
        '{ id: s, target: public.t, kind: chart, type: stat, y: [{ agg: sum, column: n }] }',
      );
      expect(
        buildTableChartSql(
          chart: stat,
          schema: 'public',
          table: 't',
          readableColumns: {'n'},
          dialect: SqlDialect.postgres,
        ).sql,
        'SELECT sum("n") AS y0 FROM "public"."t"',
      );
      final histogram = chart(
        '{ id: h, target: public.t, kind: chart, type: histogram, x: n }',
      );
      expect(
        buildTableChartSql(
          chart: histogram,
          schema: 'public',
          table: 't',
          readableColumns: {'n'},
          dialect: SqlDialect.postgres,
        ).sql,
        startsWith('SELECT "n" AS x FROM "public"."t" WHERE "n" IS NOT NULL'),
      );
    });
  });
}
