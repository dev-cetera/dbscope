import '../catalog/schema_catalog.dart';
import '../db/executor.dart';
import '../meta/masked_value.dart';
import '../util/sql_quote.dart';
import 'cancel_token.dart';

class Page {
  final List<List<Object?>> rows;
  final List<Object?>? lastSortVals;
  final List<Object?>? lastPkVals;
  Page({required this.rows, this.lastSortVals, this.lastPkVals});
}

class KeysetPager {
  final DbExecutor conn;
  final String schema;
  final String table;
  final List<ColumnInfo> columns;
  final List<String> pkColumns;
  final String? sortColumn;
  final bool descending;
  final int pageSize;

  /// Optional pre-built WHERE clause (without the leading `WHERE`) applied
  /// in addition to the keyset cursor. Placeholders should be numbered
  /// starting at `$1`; matching values go in [baseWhereParams]. Used by the
  /// navigator to filter rows by an inbound FK or a user-typed PK filter.
  final String? baseWhere;
  final List<Object?> baseWhereParams;

  /// Name every column instead of `SELECT *` on the no-PK path. Set when
  /// access control is active: the catalog may have dropped `none` columns,
  /// and `*` would fetch them anyway. (The keyed path always names columns.)
  final bool explicitColumns;

  List<Object?>? _lastSortVals;
  List<Object?>? _lastPkVals;
  bool _done = false;
  bool _started = false;

  KeysetPager({
    required this.conn,
    required this.schema,
    required this.table,
    required this.columns,
    required this.pkColumns,
    this.sortColumn,
    this.descending = false,
    this.pageSize = 500,
    this.baseWhere,
    this.baseWhereParams = const [],
    this.explicitColumns = false,
  });

  bool get isDone => _done;

  /// The SELECT list: every column the catalog returned (columns at access
  /// level `none` never get here), with masked non-key columns selected as
  /// NULL so their values never leave the database. Primary keys are always
  /// real — the keyset cursor needs them — and are masked after the cursor
  /// is taken.
  String get _selectList => columns
      .map(
        (c) => c.isMasked && !pkColumns.contains(c.name)
            ? 'NULL AS ${quoteIdent(c.name)}'
            : quoteIdent(c.name),
      )
      .join(', ');

  Set<int> get _maskedIndexes => {
    for (var i = 0; i < columns.length; i++)
      if (columns[i].isMasked) i,
  };

  Stream<Page> pages({CancelToken? cancelToken}) async* {
    if (pkColumns.isEmpty) {
      // No PK: single page LIMIT only, no further iteration.
      final qualified = quoteQualified(schema, table);
      final sortClause = sortColumn == null
          ? ''
          : ' ORDER BY ${quoteIdent(sortColumn!)} ${descending ? "DESC" : "ASC"}';
      final whereSql = (baseWhere == null || baseWhere!.isEmpty)
          ? ''
          : ' WHERE $baseWhere';
      final selectList = explicitColumns && columns.isNotEmpty
          ? _selectList
          : '*';
      final sql =
          'SELECT $selectList FROM $qualified$whereSql$sortClause LIMIT $pageSize';
      final res = baseWhereParams.isEmpty
          ? await conn.execute(sql, cancelToken: cancelToken)
          : await conn.execute(
              sql,
              positional: baseWhereParams,
              cancelToken: cancelToken,
            );
      _done = true;
      yield Page(rows: maskRows(res.rows, _maskedIndexes));
      return;
    }
    while (!_done) {
      if (cancelToken?.isCancelled ?? false) return;
      final result = await _fetchOne(cancelToken: cancelToken);
      if (cancelToken?.isCancelled ?? false) return;
      if (result.rows.isEmpty) {
        _done = true;
        return;
      }
      _lastSortVals = result.lastSortVals;
      _lastPkVals = result.lastPkVals;
      if (result.rows.length < pageSize) {
        _done = true;
      }
      yield result;
    }
  }

  Future<Page> fetchNext({CancelToken? cancelToken}) async {
    if (_done) return Page(rows: <List<Object?>>[]);
    final p = await _fetchOne(cancelToken: cancelToken);
    if (p.rows.isEmpty || p.rows.length < pageSize) _done = true;
    _lastSortVals = p.lastSortVals;
    _lastPkVals = p.lastPkVals;
    return p;
  }

  Future<Page> _fetchOne({CancelToken? cancelToken}) async {
    _started = true;
    final qualified = quoteQualified(schema, table);
    final colsSql = _selectList;
    final orderCols = <String>[
      if (sortColumn != null) quoteIdent(sortColumn!),
      for (final pk in pkColumns) quoteIdent(pk),
    ];
    final direction = descending ? 'DESC' : 'ASC';
    // Views in information_schema and arbitrary unkeyed relations can have
    // no PK and no explicit sort — omit ORDER BY entirely in that case.
    final orderClause = orderCols.isEmpty
        ? ''
        : ' ORDER BY ${orderCols.map((c) => '$c $direction').join(', ')}';
    final params = <Object?>[];
    final whereParts = <String>[];

    // Base WHERE (e.g. inbound FK filter) comes first so its placeholders
    // start at $1 — matching the numbering the caller built.
    if (baseWhere != null && baseWhere!.isNotEmpty) {
      params.addAll(baseWhereParams);
      whereParts.add(baseWhere!);
    }

    // Keyset cursor needs PK columns to seek by. Without them every page
    // would build the same `() > ()` tuple — skip the keyset and emit a
    // single LIMIT page instead (the no-PK branch in pages() does the
    // same thing for the streaming API).
    if (pkColumns.isNotEmpty && _lastPkVals != null && _started) {
      // Build keyset WHERE clause: tuple-compare for stable seek.
      final tupleCols = orderCols.join(', ');
      final placeholders = <String>[];
      if (sortColumn != null) {
        params.add(_lastSortVals?.first);
        placeholders.add('\$${params.length}');
      }
      for (final v in _lastPkVals!) {
        params.add(v);
        placeholders.add('\$${params.length}');
      }
      final op = descending ? '<' : '>';
      whereParts.add('($tupleCols) $op (${placeholders.join(', ')})');
    }

    final whereClause = whereParts.isEmpty
        ? ''
        : ' WHERE ${whereParts.join(' AND ')}';

    final sql =
        'SELECT $colsSql FROM $qualified$whereClause$orderClause LIMIT $pageSize';
    final result = params.isEmpty
        ? await conn.execute(sql, cancelToken: cancelToken)
        : await conn.execute(sql, positional: params, cancelToken: cancelToken);

    if (result.isEmpty) {
      _done = true;
      return Page(rows: <List<Object?>>[]);
    }
    final rows = result.rows;
    // No PK -> no keyset cursor possible. Return this single page and
    // stop; callers like TableLoader/fetchNext won't try a second query.
    if (pkColumns.isEmpty) {
      _done = true;
      return Page(rows: maskRows(rows, _maskedIndexes));
    }
    final last = rows.last;
    final colNames = columns.map((c) => c.name).toList();
    final pkVals = [
      for (final pk in pkColumns)
        if (colNames.contains(pk)) last[colNames.indexOf(pk)] else null,
    ];
    final sortVals = sortColumn == null
        ? null
        : [
            if (colNames.contains(sortColumn))
              last[colNames.indexOf(sortColumn!)]
            else
              null,
          ];
    return Page(
      rows: maskRows(rows, _maskedIndexes),
      lastSortVals: sortVals,
      lastPkVals: pkVals,
    );
  }
}
