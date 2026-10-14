// Runs a ChartSpec and normalises the result into series a chart widget
// can draw. All access checks happen here, before any SQL runs:
//   - table charts only name readable columns (buildTableChartSql);
//   - query charts need `read` on the query and on every column they plot;
//   - inline-SQL (row) charts bind @row_<col> from the row like actions.
//
// Timeouts are client-side (the window's connection is shared with the
// grid, so a session-level statement_timeout would leak onto other
// queries): after `timeoutMs` the chart stops waiting and says so; the
// database may still finish the statement.

import 'dart:async';

import '../../catalog/schema_catalog.dart';
import '../../db/executor.dart';
import '../../util/sql_quote.dart';
import '../access_policy.dart';
import '../action_binding.dart';
import '../chart_sql.dart';
import '../masked_value.dart';
import '../meta_cache.dart';
import '../meta_models.dart';
import '../meta_sources.dart';
import '../read_only_exec.dart';

/// How long the client waits past the chart's own timeout before giving up,
/// so the server's cancellation normally arrives first.
const _kClientTimeoutGrace = Duration(seconds: 5);

class ChartSeriesData {
  const ChartSeriesData(this.name, this.values);
  final String name;
  final List<double?> values;
}

class ChartData {
  const ChartData({
    this.xLabels = const [],
    this.xNumbers,
    this.series = const [],
    this.stat,
  });

  /// Category / bucket labels along x (empty for `stat`).
  final List<String> xLabels;

  /// Numeric x values when every x is a number (scatter, histogram).
  final List<double>? xNumbers;
  final List<ChartSeriesData> series;

  /// For `stat`: the single value.
  final double? stat;

  bool get isEmpty =>
      series.every((entry) => entry.values.isEmpty) && stat == null;
}

class ChartRunError implements Exception {
  const ChartRunError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A finite double, or null. NaN/Infinity (legal in float columns) would
/// break histogram binning and every fl_chart axis.
double? _toDouble(Object? value) {
  if (value == null || value is MaskedValue) return null;
  final double? result;
  if (value is num) {
    result = value.toDouble();
  } else if (value is DateTime) {
    result = value.millisecondsSinceEpoch.toDouble();
  } else {
    result = double.tryParse(value.toString());
  }
  return result != null && result.isFinite ? result : null;
}

String _label(Object? value) {
  if (value == null) return '∅';
  if (value is DateTime) {
    final utc = value.toUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    final date = '${utc.year}-${two(utc.month)}-${two(utc.day)}';
    if (utc.hour == 0 && utc.minute == 0 && utc.second == 0) return date;
    return '$date ${two(utc.hour)}:${two(utc.minute)}';
  }
  return value.toString();
}

/// Runs [chart] against [executor]. [row] supplies `@row_<col>` values for
/// row-scoped charts.
Future<ChartData> runChart(
  ChartSpec chart, {
  required DbExecutor executor,
  BindingContext row = const BindingContext(),
}) async {
  final snapshot = MetadataCache.instance.snapshotForExecutor(executor);
  final policy = snapshot?.policy ?? AccessPolicy.unrestricted;
  final dialect = isSqliteExecutor(executor)
      ? SqlDialect.sqlite
      : SqlDialect.postgres;
  final timeout = Duration(milliseconds: chart.timeoutMs.clamp(500, 120000));

  // The server cancels at [timeout] (statement_timeout inside the read-only
  // fence); the client-side timeout is only a backstop for backends that
  // can't be fenced.
  Future<DbResult> run(String sql, [Map<String, Object?>? named]) =>
      executeReadOnly(executor, sql, named: named, timeout: timeout).timeout(
        timeout + _kClientTimeoutGrace,
        onTimeout: () => throw ChartRunError(
          'Chart "${chart.label}" took longer than '
          '${timeout.inSeconds}s and was abandoned.',
        ),
      );

  final source = chart.source;
  switch (source) {
    case ChartTableSource(:final schema, :final table):
      if (policy.forTable(schema, table).level.index <
          AccessLevel.masked.index) {
        throw ChartRunError('$schema.$table is not available.');
      }
      final columns = await SchemaCatalog(executor).listColumns(schema, table);
      final readable = {
        for (final column in columns)
          if (column.accessLevel.atLeast(AccessLevel.read)) column.name,
      };
      final softDelete = snapshot?.index.policyTable(schema, table).softDelete;
      final extraWhere = softDelete != null && readable.contains(softDelete)
          ? '${quoteIdent(softDelete)} IS NULL'
          : null;
      final ChartSql built;
      try {
        built = buildTableChartSql(
          chart: chart,
          schema: schema,
          table: table,
          readableColumns: readable,
          dialect: dialect,
          extraWhere: extraWhere,
        );
      } on ChartSqlError catch (e) {
        throw ChartRunError(e.message);
      }
      final result = await run(built.sql);
      return _shape(
        chart,
        result,
        xName: 'x',
        seriesName: built.hasSeries ? 'series' : null,
        measureNames: [for (var i = 0; i < built.measureCount; i++) 'y$i'],
      );
    case ChartQuerySource(:final queryId):
      final query = snapshot?.index.queryById(queryId);
      if (query == null) {
        throw ChartRunError('Named query "$queryId" does not exist.');
      }
      if (!policy.forQuery(queryId).canSeeValues) {
        throw ChartRunError('You cannot run the query "${query.label}".');
      }
      final plotted = [
        ?chart.x,
        ?chart.series,
        for (final measure in chart.y) ?measure.column,
      ];
      for (final column in plotted) {
        if (!policy.forQueryColumn(queryId, column).canSeeValues) {
          throw ChartRunError(
            'Column "$column" of "${query.label}" is hidden.',
          );
        }
      }
      if (findPlaceholders(query.sql).isNotEmpty) {
        throw ChartRunError(
          'The query "${query.label}" needs inputs; open it to chart it.',
        );
      }
      final result = await run(query.sql);
      return _shape(
        chart,
        result,
        xName: chart.x,
        seriesName: chart.series,
        measureNames: [
          for (final measure in chart.y) measure.column ?? measure.label ?? 'y',
        ],
      );
    case ChartSqlSource(:final sql):
      final bound = bindSql(sql, row);
      if (!bound.isComplete) {
        throw ChartRunError(
          'Chart "${chart.label}" needs ${bound.missing.join(', ')}.',
        );
      }
      final result = await run(bound.sql, bound.named);
      return _shape(
        chart,
        result,
        xName: chart.x,
        seriesName: chart.series,
        measureNames: [
          for (final measure in chart.y) measure.column ?? measure.label ?? 'y',
        ],
      );
  }
}

ChartData _shape(
  ChartSpec chart,
  DbResult result, {
  required String? xName,
  required String? seriesName,
  required List<String> measureNames,
}) {
  final names = [for (final column in result.columns) column.name];
  int indexOf(String? name, {int? fallback}) {
    if (name == null) return fallback ?? -1;
    final i = names.indexOf(name);
    return i >= 0 ? i : (fallback ?? -1);
  }

  if (chart.type == ChartType.histogram) {
    final xi = indexOf(xName, fallback: 0);
    final values = [
      for (final row in result.rows)
        if (xi >= 0 && xi < row.length) ?_toDouble(row[xi]),
    ];
    return _histogram(values);
  }

  final measureIndexes = [
    for (var i = 0; i < measureNames.length; i++)
      indexOf(measureNames[i], fallback: names.length > i + 1 ? i + 1 : -1),
  ];

  if (chart.type == ChartType.stat || xName == null) {
    final first = result.rows.isEmpty ? null : result.rows.first;
    final measureColumnIndex = measureIndexes.isEmpty
        ? 0
        : measureIndexes.first;
    return ChartData(
      stat:
          first == null ||
              measureColumnIndex < 0 ||
              measureColumnIndex >= first.length
          ? null
          : _toDouble(first[measureColumnIndex]),
    );
  }

  final xi = indexOf(xName, fallback: 0);
  final si = indexOf(seriesName);
  final xKeys = <String>[];
  final xNumbers = <double>[];
  var allNumericX = true;
  final bySeries = <String, Map<String, double?>>{};
  for (final row in _ascendingByX(result.rows, xi)) {
    final xValue = xi >= 0 && xi < row.length ? row[xi] : null;
    final xKey = _label(xValue);
    if (!xKeys.contains(xKey)) {
      xKeys.add(xKey);
      final xNumber = _toDouble(xValue);
      if (xNumber == null || xValue is DateTime) {
        allNumericX = false;
      } else {
        xNumbers.add(xNumber);
      }
    }
    for (var measure = 0; measure < measureIndexes.length; measure++) {
      final measureColumnIndex = measureIndexes[measure];
      final seriesKey = si >= 0
          ? _label(row[si])
          : (chart.y[measure].label ?? measureNames[measure]);
      final value = measureColumnIndex >= 0 && measureColumnIndex < row.length
          ? _toDouble(row[measureColumnIndex])
          : null;
      (bySeries[seriesKey] ??= {})[xKey] = value;
    }
  }
  return ChartData(
    xLabels: xKeys,
    xNumbers: allNumericX && xNumbers.length == xKeys.length ? xNumbers : null,
    series: [
      for (final e in bySeries.entries)
        ChartSeriesData(e.key, [for (final xKey in xKeys) e.value[xKey]]),
    ],
  );
}

/// [rows] in ascending x order when every x is a time or a number, so a
/// named query sorted newest-first still plots left to right; any other x
/// (labels, categories) keeps the query's own order.
List<List<Object?>> _ascendingByX(List<List<Object?>> rows, int xi) {
  if (xi < 0 || rows.isEmpty) return rows;
  Object? xOf(List<Object?> row) => xi < row.length ? row[xi] : null;
  final allTimes = rows.every((row) => xOf(row) is DateTime);
  final allNumbers = rows.every((row) => xOf(row) is num);
  if (!allTimes && !allNumbers) return rows;
  double keyOf(List<Object?> row) {
    final value = xOf(row);
    return value is DateTime
        ? value.microsecondsSinceEpoch.toDouble()
        : (value! as num).toDouble();
  }

  // List.sort isn't stable; the index tie-break keeps equal x values (one
  // per series) in the query's order.
  final indexed = [for (var i = 0; i < rows.length; i++) (i, rows[i])];
  indexed.sort((a, b) {
    final byX = keyOf(a.$2).compareTo(keyOf(b.$2));
    return byX != 0 ? byX : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// Sturges' rule bins, capped at 40.
ChartData _histogram(List<double> values) {
  if (values.isEmpty) return const ChartData();
  values.sort();
  final min = values.first;
  final max = values.last;
  if (min == max) {
    return ChartData(
      xLabels: [_fmt(min)],
      series: [
        ChartSeriesData('rows', [values.length.toDouble()]),
      ],
    );
  }
  final bins = (1 + values.length.bitLength).clamp(5, 40);
  final width = (max - min) / bins;
  final counts = List<double>.filled(bins, 0);
  for (final value in values) {
    var i = ((value - min) / width).floor();
    if (i >= bins) i = bins - 1;
    counts[i]++;
  }
  return ChartData(
    xLabels: [
      for (var i = 0; i < bins; i++) _fmt(min + i * width),
    ],
    series: [ChartSeriesData('rows', counts)],
  );
}

String _fmt(double value) {
  if (value.abs() >= 1000 || value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(2);
}
