import '../catalog/schema_catalog.dart';
import '../db/executor.dart';
import '../db/sqlite_kind.dart';
import '../meta/masked_value.dart';
import '../util/sql_quote.dart';
import 'cancel_token.dart';

/// Types Postgres can sort out of the box. A column of any other type (json,
/// xml, point, a custom type) would make ORDER BY fail, so it can't be a
/// tiebreaker.
const _kSortableTypeNames = {
  'bool', 'int2', 'int4', 'int8', 'float4', 'float8', 'numeric', 'money', 'oid',
  'text', 'varchar', 'bpchar', 'char', 'name', 'uuid', 'bytea',
  'date', 'time', 'timetz', 'timestamp', 'timestamptz', 'interval',
  'inet', 'cidr', 'macaddr',
};

class Page {
  Page({required this.rows, this.lastSortVals, this.lastPkVals});
  final List<List<Object?>> rows;
  final List<Object?>? lastSortVals;
  final List<Object?>? lastPkVals;
}

class KeysetPager {
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
  List<Object?>? _lastPrimaryKeyValues;
  var _done = false;
  var _started = false;

  /// Rows fetched so far. Only the no-PK path pages by it (OFFSET); a keyed
  /// table seeks by cursor instead.
  var _fetchedRows = 0;

  bool get isDone => _done;

  /// The SELECT list: every column the catalog returned (columns at access
  /// level `none` never get here), with masked non-key columns selected as
  /// NULL so their values never leave the database. Primary keys are always
  /// real — the keyset cursor needs them — and are masked after the cursor
  /// is taken.
  String get _selectList => columns
      .map(
        (column) => column.isMasked && !pkColumns.contains(column.name)
            ? 'NULL AS ${quoteIdent(column.name)}'
            : quoteIdent(column.name),
      )
      .join(', ');

  Set<int> get _maskedIndexes => {
    for (var i = 0; i < columns.length; i++)
      if (columns[i].isMasked) i,
  };

  Stream<Page> pages({CancelToken? cancelToken}) async* {
    while (!_done) {
      if (cancelToken?.isCancelled ?? false) return;
      final result = await _fetchOne(cancelToken: cancelToken);
      if (cancelToken?.isCancelled ?? false) return;
      if (result.rows.isEmpty) {
        _done = true;
        return;
      }
      _lastSortVals = result.lastSortVals;
      _lastPrimaryKeyValues = result.lastPkVals;
      if (result.rows.length < pageSize) {
        _done = true;
      }
      yield result;
    }
  }

  Future<Page> fetchNext({CancelToken? cancelToken}) async {
    if (_done) return Page(rows: <List<Object?>>[]);
    final page = await _fetchOne(cancelToken: cancelToken);
    // Cancelled: _fetchOne left the state alone; don't overwrite the
    // cursor with the empty page's (null) keys.
    if (cancelToken?.isCancelled ?? false) return page;
    if (page.rows.isEmpty || page.rows.length < pageSize) _done = true;
    _lastSortVals = page.lastSortVals;
    _lastPrimaryKeyValues = page.lastPkVals;
    return page;
  }

  Future<Page> _fetchOne({CancelToken? cancelToken}) async {
    _started = true;
    final qualified = quoteQualified(schema, table);
    final colsSql = pkColumns.isEmpty && !(explicitColumns && columns.isNotEmpty) ? '*' : _selectList;
    final orderColumns = <String>[
      if (sortColumn != null) quoteIdent(sortColumn!),
      for (final primaryKey in pkColumns) quoteIdent(primaryKey),
      ..._offsetTiebreakers.map(quoteIdent),
    ];
    final direction = descending ? 'DESC' : 'ASC';
    // Views in information_schema and arbitrary unkeyed relations can have
    // no PK and no explicit sort — omit ORDER BY entirely in that case.
    final orderClause = orderColumns.isEmpty
        ? ''
        : ' ORDER BY ${orderColumns.map((orderColumn) => '$orderColumn $direction').join(', ')}';
    final params = <Object?>[];
    final whereParts = <String>[];

    // Base WHERE (e.g. inbound FK filter) comes first so its placeholders
    // start at $1 — matching the numbering the caller built.
    if (baseWhere != null && baseWhere!.isNotEmpty) {
      params.addAll(baseWhereParams);
      whereParts.add(baseWhere!);
    }

    // The keyset cursor needs PK columns to seek by; without them the
    // OFFSET below does the paging.
    if (pkColumns.isNotEmpty && _lastPrimaryKeyValues != null && _started) {
      whereParts.add(_cursorPredicate(params));
    }

    final whereClause = whereParts.isEmpty ? '' : ' WHERE ${whereParts.join(' AND ')}';

    // No primary key means no cursor to seek by, so a table without one
    // pages by OFFSET: slower deep in the table, but every row is reachable.
    final offsetClause = pkColumns.isEmpty && _fetchedRows > 0 ? ' OFFSET $_fetchedRows' : '';
    final sql = 'SELECT $colsSql FROM $qualified$whereClause$orderClause LIMIT $pageSize$offsetClause';
    final result = params.isEmpty
        ? await conn.execute(sql, cancelToken: cancelToken)
        : await conn.execute(sql, positional: params, cancelToken: cancelToken);
    // A cancelled fetch leaves the pager where it was. Some executors
    // return no rows once cancelled, which below would read as the end of
    // the table and stop paging for good.
    if (cancelToken?.isCancelled ?? false) return Page(rows: <List<Object?>>[]);

    if (result.isEmpty) {
      _done = true;
      return Page(rows: <List<Object?>>[]);
    }
    final rows = result.rows;
    if (pkColumns.isEmpty) {
      _fetchedRows += rows.length;
      return Page(rows: maskRows(rows, _maskedIndexes));
    }
    final last = rows.last;
    final columnNames = columns.map((column) => column.name).toList();
    final primaryKeyValues = [
      for (final primaryKey in pkColumns)
        if (columnNames.contains(primaryKey)) last[columnNames.indexOf(primaryKey)] else null,
    ];
    final sortValues = sortColumn == null
        ? null
        : [
            if (columnNames.contains(sortColumn)) last[columnNames.indexOf(sortColumn!)] else null,
          ];
    return Page(
      rows: maskRows(rows, _maskedIndexes),
      lastSortVals: sortValues,
      lastPkVals: primaryKeyValues,
    );
  }

  /// OFFSET paging is only right if every query returns the rows in the same
  /// order, and rows that tie on the sort column have no order of their own.
  /// So a sorted table without a primary key also sorts by its other columns.
  /// Rows equal in all of them are interchangeable, so it can't matter which
  /// page gets which. Masked columns stay out, as sorting by one would reveal
  /// its values. An unsorted table stays unordered: sorting it would turn
  /// opening a huge table into a full scan per page.
  Iterable<String> get _offsetTiebreakers {
    if (pkColumns.isNotEmpty || sortColumn == null) return const [];
    final sortable = conn.kind == kSqliteKind
        ? columns
        : columns.where((column) => _kSortableTypeNames.contains(column.typeName));
    return [
      for (final column in sortable)
        if (column.name != sortColumn && !column.isMasked) column.name,
    ];
  }

  /// Where NULLs of the sort column fall in this backend's default order
  /// (the ORDER BY carries no NULLS FIRST/LAST, so an index still serves
  /// it): Postgres sorts NULL as the largest value, SQLite as the smallest.
  bool get _nullsFirst =>
      conn.kind == kSqliteKind ? !descending : descending;

  /// The keyset cursor: rows strictly after the last one fetched. Appends
  /// its values to [params].
  ///
  /// A plain `(sort, pk) > (last…)` tuple compare is NULL as soon as either
  /// side holds a NULL sort value, which matched no row and ended paging at
  /// the first NULL. So a nullable sort column splits the cursor into the
  /// NULL and non-NULL runs, in the order the backend sorts them.
  String _cursorPredicate(List<Object?> params) {
    final op = descending ? '<' : '>';
    final pkTuple = pkColumns.map(quoteIdent).join(', ');
    String pkPlaceholders() {
      final placeholders = <String>[];
      for (final value in _lastPrimaryKeyValues!) {
        params.add(value);
        placeholders.add('\$${params.length}');
      }
      return placeholders.join(', ');
    }

    final sort = sortColumn;
    if (sort == null) return '($pkTuple) $op (${pkPlaceholders()})';

    final sortIdent = quoteIdent(sort);
    final lastSort = _lastSortVals?.first;
    final nullable = columns.any((column) => column.name == sort && column.nullable);

    if (lastSort != null) {
      params.add(lastSort);
      final sortPlaceholder = '\$${params.length}';
      final tuple = '($sortIdent, $pkTuple) $op ($sortPlaceholder, ${pkPlaceholders()})';
      if (!nullable) return tuple;
      // Non-NULL run: the tuple compare. NULLs still to come when they sort
      // last; already passed when they sort first.
      return _nullsFirst ? tuple : '($tuple OR $sortIdent IS NULL)';
    }
    // The last row's sort value is NULL: continue inside the NULL run by
    // primary key, then (when NULLs sort first) on to every non-NULL row.
    final inNullRun = '($sortIdent IS NULL AND ($pkTuple) $op (${pkPlaceholders()}))';
    return _nullsFirst ? '($inNullRun OR $sortIdent IS NOT NULL)' : inNullRun;
  }
}
