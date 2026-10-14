// Builds the SQL behind a chart whose source is a table, so a chart needs
// no hand-written SQL. Identifiers go through quoteIdent, aggregates come
// from a fixed list, time buckets and ranges from fixed enums — nothing
// user-typed is ever pasted into the SQL.
//
// Every chart query returns columns named:
//   x        the category / bucket (absent for `stat`)
//   series   the series value (only when the chart has a series)
//   y0..yN   one per measure
// Histograms return the raw values as `x` and bin client-side.

import '../util/sql_quote.dart';
import 'meta_models.dart';

enum SqlDialect { postgres, sqlite }

class ChartSqlError implements Exception {
  const ChartSqlError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Rows a histogram reads before binning.
const kHistogramSampleRows = 10000;

class ChartSql {
  const ChartSql(
    this.sql, {
    required this.measureCount,
    required this.hasSeries,
  });
  final String sql;
  final int measureCount;
  final bool hasSeries;
}

/// [readableColumns] is every column the viewer may read (access level
/// `read` or above). A chart that names any other column is refused, so a
/// chart can't be used to peek at a masked column.
ChartSql buildTableChartSql({
  required ChartSpec chart,
  required String schema,
  required String table,
  required Set<String> readableColumns,
  required SqlDialect dialect,
  String? extraWhere,
}) {
  void requireReadable(String? column, String role) {
    if (column == null) return;
    if (!readableColumns.contains(column)) {
      throw ChartSqlError(
        'Chart "${chart.label}": $role column "$column" is not readable here.',
      );
    }
  }

  requireReadable(chart.x, 'x');
  requireReadable(chart.series, 'series');
  requireReadable(chart.rangeColumn, 'range');
  for (final measure in chart.y) {
    requireReadable(measure.column, 'y');
  }

  final from = quoteQualified(schema, table);
  final where = <String>[?extraWhere];
  final rangeClause = _rangeClause(chart, dialect);
  if (rangeClause != null) where.add(rangeClause);

  if (chart.type == ChartType.histogram) {
    final xColumn = chart.x;
    if (xColumn == null) {
      throw ChartSqlError('Chart "${chart.label}": a histogram needs x.');
    }
    final xIdent = quoteIdent(xColumn);
    where.add('$xIdent IS NOT NULL');
    return ChartSql(
      'SELECT $xIdent AS x FROM $from WHERE ${where.join(' AND ')} '
      'LIMIT $kHistogramSampleRows',
      measureCount: 0,
      hasSeries: false,
    );
  }

  final measures = [
    for (var i = 0; i < chart.y.length; i++)
      '${_measureSql(chart.y[i], chart.label)} AS y$i',
  ];
  final whereSql = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';

  if (chart.type == ChartType.stat || chart.x == null) {
    return ChartSql(
      'SELECT ${measures.join(', ')} FROM $from$whereSql',
      measureCount: measures.length,
      hasSeries: false,
    );
  }

  final xExpr = _bucketExpr(quoteIdent(chart.x!), chart.bucket, dialect);
  final selects = ['$xExpr AS x'];
  final groups = [xExpr];
  final series = chart.series;
  if (series != null) {
    selects.add('${quoteIdent(series)} AS series');
    groups.add(quoteIdent(series));
  }
  selects.addAll(measures);

  // Categorical charts (pie, bar without a time bucket) show the biggest
  // categories; time charts read in time order.
  final isTimeSeries = chart.bucket != null;
  final orderBy =
      isTimeSeries ||
          chart.type == ChartType.line ||
          chart.type == ChartType.area ||
          chart.type == ChartType.scatter
      ? 'x'
      : 'y0 DESC';
  final limit = chart.limit.clamp(1, 5000);
  return ChartSql(
    'SELECT ${selects.join(', ')} FROM $from$whereSql '
    'GROUP BY ${groups.join(', ')} ORDER BY $orderBy LIMIT $limit',
    measureCount: measures.length,
    hasSeries: series != null,
  );
}

String _measureSql(ChartMeasure measure, String chartLabel) {
  final aggregate = measure.aggregate ?? ChartAggregate.count;
  final column = measure.column;
  if (aggregate == ChartAggregate.count) {
    return column == null ? 'count(*)' : 'count(${quoteIdent(column)})';
  }
  if (column == null) {
    throw ChartSqlError(
      'Chart "$chartLabel": ${aggregate.name} needs a column.',
    );
  }
  final ident = quoteIdent(column);
  return switch (aggregate) {
    ChartAggregate.count => 'count($ident)',
    ChartAggregate.sum => 'sum($ident)',
    ChartAggregate.avg => 'avg($ident)',
    ChartAggregate.min => 'min($ident)',
    ChartAggregate.max => 'max($ident)',
    ChartAggregate.countDistinct => 'count(DISTINCT $ident)',
  };
}

/// A SQLite expression yielding `YYYY-MM-DD HH:MM:SS` UTC text for a time
/// column, whatever it stores: epoch seconds or milliseconds (integers or
/// reals — common in apps) or ISO text (with a 'T' or a space). Without
/// this, strftime reads integers as Julian days and text comparisons against
/// datetime() go wrong on the boundary day.
String _sqliteTime(String ident) =>
    "CASE WHEN typeof($ident) IN ('integer', 'real') "
    'THEN datetime(CASE WHEN $ident > 100000000000 '
    "THEN $ident / 1000 ELSE $ident END, 'unixepoch') "
    'ELSE datetime($ident) END';

String _bucketExpr(String ident, ChartBucket? bucket, SqlDialect dialect) {
  if (bucket == null) return ident;
  if (dialect == SqlDialect.postgres) {
    return "date_trunc('${bucket.name}', $ident)";
  }
  final time = _sqliteTime(ident);
  return switch (bucket) {
    ChartBucket.hour => "strftime('%Y-%m-%d %H:00', $time)",
    ChartBucket.day => "strftime('%Y-%m-%d', $time)",
    ChartBucket.week => "strftime('%Y-W%W', $time)",
    ChartBucket.month => "strftime('%Y-%m', $time)",
    ChartBucket.year => "strftime('%Y', $time)",
  };
}

String? _rangeClause(ChartSpec chart, SqlDialect dialect) {
  final duration = chart.range.duration;
  // The time column: explicit, else x when x is time-bucketed (or the
  // chart plots values over time). A categorical x never takes a range.
  final column =
      chart.rangeColumn ??
      (chart.bucket != null ||
              chart.type == ChartType.line ||
              chart.type == ChartType.area
          ? chart.x
          : null);
  if (duration == null || column == null) return null;
  final ident = quoteIdent(column);
  final hours = duration.inHours;
  if (dialect == SqlDialect.postgres) {
    return "$ident >= now() - interval '$hours hours'";
  }
  return "${_sqliteTime(ident)} >= datetime('now', '-$hours hours')";
}
