import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../connection/profile.dart';
import '../db/edit_policies.dart';
import '../db/edit_policy.dart';
import '../db/executor.dart';
import '../grid/data_grid.dart';
import '../meta/access_policy.dart';
import '../meta/masked_value.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../meta/read_only_exec.dart';
import '../util/sql_parse.dart';
import '../util/sql_quote.dart';
import 'cancel_token.dart';
import 'pager.dart';

class QueryRunResult {
  const QueryRunResult({
    required this.data,
    required this.elapsed,
    this.truncated = false,
  });
  final GridData data;
  final Duration elapsed;
  final bool truncated;
}

class TableLoadResult {
  const TableLoadResult({
    required this.columns,
    required this.pkColumns,
    required this.indexedColumns,
    required this.editPolicies,
    required this.pager,
    required this.firstRows,
    required this.elapsed,
    this.effectiveSoftDeleteColumn,
    this.tenantFilterApplied = false,
    this.tableAccess = AccessDecision.unrestricted,
    this.defaultFilterApplied,
    this.defaultFilterPending = false,
    this.effectiveSort,
    this.hardDeleteRefusal,
    this.deleteRefusal,
    this.returningList = '*',
  });
  final List<ColumnInfo> columns;
  final List<String> pkColumns;
  final Set<String> indexedColumns;
  final List<EditPolicy> editPolicies;
  final KeysetPager pager;
  final List<List<Object?>> firstRows;
  final Duration elapsed;

  /// The soft-delete column configured for this table, if any AND it
  /// actually exists in [columns]. UI uses this to gate the "Show
  /// deleted" toggle and to swap DELETE for UPDATE. Null when no
  /// override is configured or the configured column was removed from
  /// the schema since the user set it.
  final String? effectiveSoftDeleteColumn;

  /// True iff a tenant filter applied to this table (i.e. the profile
  /// has one configured AND the table has the column). UI uses this to
  /// show a badge so users aren't confused why row counts look low.
  final bool tenantFilterApplied;

  /// The viewer's access to the table as a whole (schema metadata access
  /// control). `full` when no access control applies.
  final AccessDecision tableAccess;

  /// Metadata `display.defaultFilter` applied to this load, if any.
  final String? defaultFilterApplied;

  /// A default filter exists but was not applied because the metadata SQL
  /// is not trusted yet.
  final bool defaultFilterPending;

  /// The sort actually used: the caller's, or metadata `defaultSort`.
  final ({String column, bool descending})? effectiveSort;

  /// Set when metadata forbids hard deletes on this table
  /// (`policy.danger: hardDelete`): the message to show instead.
  final String? hardDeleteRefusal;

  /// Set when metadata forbids any delete (`policy.danger: delete`).
  final String? deleteRefusal;

  /// Expression list for `INSERT … RETURNING`, matching [columns] (masked
  /// columns come back as NULL, `none` columns not at all).
  final String returningList;

  bool get canInsert => tableAccess.level.atLeast(AccessLevel.full);
  bool get canDelete => tableAccess.level.atLeast(AccessLevel.full);

  /// Indexes of masked columns, for masking a freshly inserted row.
  Set<int> get maskedIndexes => {
    for (var i = 0; i < columns.length; i++)
      if (columns[i].isMasked) i,
  };

  GridData toGridData() => GridData(
    columns: [
      for (final c in columns)
        gridColumn(name: c.name, type: c.type, typeName: c.typeName),
    ],
    rows: firstRows,
  );
}

class TableLoader {
  TableLoader(this.conn, {this.connectionReadOnly = true});
  final DbExecutor conn;
  final bool connectionReadOnly;

  Future<TableLoadResult> loadTable({
    required String schema,
    required String table,
    ConnectionProfile? profile,
    bool showDeleted = false,
    String? sortColumn,
    bool descending = false,
    int pageSize = 500,
    CancelToken? cancelToken,
    String? baseWhere,
    List<Object?> baseWhereParams = const [],
    bool defaultFilterTrusted = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    final snapshot = MetadataCache.instance.snapshotForExecutor(conn);
    final access = snapshot?.policy ?? AccessPolicy.unrestricted;
    final tableAccess = access.forTable(schema, table);
    if (tableAccess.isNone) {
      throw StateError(
        '$schema.$table is not available. ${tableAccess.reason}',
      );
    }
    final catalog = SchemaCatalog(conn);
    // The three catalog queries are independent. Fire them in parallel so
    // we pay one pipelined round-trip for the lot instead of three serial
    // ones — biggest win on a high-latency / remote DB.
    final catalogResults = await Future.wait<Object>([
      catalog.listColumns(schema, table),
      catalog.primaryKey(schema, table),
      catalog.indexedColumns(schema, table),
    ]);
    final columns = catalogResults[0] as List<ColumnInfo>;
    final pk = catalogResults[1] as List<String>;
    final indexed = catalogResults[2] as Set<String>;
    final columnNames = {for (final c in columns) c.name};
    final maskedNames = {
      for (final c in columns)
        if (c.isMasked) c.name,
    };

    final index = snapshot?.index;
    final tablePolicy = index?.policyTable(schema, table);
    final display = index?.displayTable(schema, table);

    // The sort: the caller's, else metadata's defaultSort — never a masked
    // column (its values are NULL here, so a keyset cursor on it breaks).
    var sort = sortColumn == null
        ? display?.parsedDefaultSort
        : (column: sortColumn, descending: descending);
    if (sort != null &&
        (!columnNames.contains(sort.column) ||
            maskedNames.contains(sort.column))) {
      sort = null;
    }

    // A metadata default filter is SQL from the metadata: it applies only
    // once the user trusted the connection's metadata SQL.
    final defaultFilter = defaultFilterTrusted ? display?.defaultFilter : null;
    final defaultFilterPending =
        !defaultFilterTrusted && display?.defaultFilter != null;
    final composed = _composeBaseWhere(
      profile: profile,
      metaSoftDelete: tablePolicy?.softDelete,
      schema: schema,
      table: table,
      columns: columns,
      showDeleted: showDeleted,
      callerWhere: baseWhere,
      callerParams: baseWhereParams,
      defaultFilter: defaultFilter,
    );

    final pager = KeysetPager(
      conn: conn,
      schema: schema,
      table: table,
      columns: columns,
      pkColumns: pk,
      sortColumn: sort?.column,
      descending: sort?.descending ?? false,
      pageSize: pageSize,
      baseWhere: composed.where,
      baseWhereParams: composed.params,
      explicitColumns: access.active,
    );
    final first = await pager.fetchNext(cancelToken: cancelToken);
    stopwatch.stop();

    final policies = buildEditPolicies(
      conn: conn,
      schema: schema,
      table: table,
      columns: columns,
      pkColumns: pk,
      connectionReadOnly: connectionReadOnly,
    );

    final returningList = [
      for (final c in columns)
        if (c.isMasked && !pk.contains(c.name))
          'NULL AS ${quoteIdent(c.name)}'
        else
          quoteIdent(c.name),
    ].join(', ');

    return TableLoadResult(
      columns: columns,
      pkColumns: pk,
      indexedColumns: indexed,
      editPolicies: policies,
      pager: pager,
      firstRows: first.rows,
      elapsed: stopwatch.elapsed,
      effectiveSoftDeleteColumn: composed.effectiveSoftDeleteColumn,
      tenantFilterApplied: composed.tenantFilterApplied,
      tableAccess: tableAccess,
      defaultFilterApplied: composed.defaultFilterApplied,
      defaultFilterPending: defaultFilterPending,
      effectiveSort: sort,
      hardDeleteRefusal: (tablePolicy?.forbidsHardDelete ?? false)
          ? (tablePolicy?.message ??
                'Metadata forbids hard deletes on this table.')
          : null,
      deleteRefusal: (tablePolicy?.forbidsAnyDelete ?? false)
          ? (tablePolicy?.message ?? 'Metadata forbids deleting rows here.')
          : null,
      returningList: columns.isEmpty ? '*' : returningList,
    );
  }
}

/// Masks the cells of a row returned by `INSERT … RETURNING` the same way
/// the pager masks fetched rows.
List<Object?> maskInsertedRow(List<Object?> row, Set<int> maskedIndexes) =>
    maskRows([row], maskedIndexes).first;

class _ComposedWhere {
  const _ComposedWhere({
    required this.where,
    required this.params,
    required this.effectiveSoftDeleteColumn,
    required this.tenantFilterApplied,
    this.defaultFilterApplied,
  });
  final String? where;
  final List<Object?> params;
  final String? effectiveSoftDeleteColumn;
  final bool tenantFilterApplied;
  final String? defaultFilterApplied;
}

/// Build the WHERE clause that gets passed to [KeysetPager], merging:
/// 1. The caller's existing baseWhere (navigator inbound-FK filter, etc.).
/// Its placeholders start at $1 — we keep that numbering by appending
/// our own clauses AFTER the caller's params and using continuation
/// placeholder numbers ($N+1, $N+2, …).
/// 2. The profile's tenant filter, when the table has the configured
/// column.
/// 3. The table's soft-delete `<col> IS NULL` filter, when configured
/// AND `showDeleted` is false. (Soft-delete with `now()` is a fixed
/// literal `IS NULL` check — no params.)
_ComposedWhere _composeBaseWhere({
  required ConnectionProfile? profile,
  required String? metaSoftDelete,
  required String? defaultFilter,
  required String schema,
  required String table,
  required List<ColumnInfo> columns,
  required bool showDeleted,
  required String? callerWhere,
  required List<Object?> callerParams,
}) {
  final colNames = {for (final c in columns) c.name};
  final params = <Object?>[...callerParams];
  final parts = <String>[];
  if (callerWhere != null && callerWhere.isNotEmpty) {
    // Parenthesised: an `a OR b` filter must not swallow the soft-delete /
    // tenant parts ANDed after it.
    parts.add('($callerWhere)');
  }

  var tenantApplied = false;
  final tenant = profile?.tenantFilter;
  if (tenant != null && colNames.contains(tenant.column)) {
    params.add(tenant.value);
    parts.add('${quoteIdent(tenant.column)} = \$${params.length}');
    tenantApplied = true;
  }

  String? effectiveSoftDelete;
  // The live profile override wins (it may have changed in another window
  // since the metadata snapshot was taken); metadata's `softDelete` applies
  // when the profile sets none.
  final overrides = profile?.overridesFor(schema, table);
  final softDeleteCol = overrides?.softDeleteColumn ?? metaSoftDelete;
  if (softDeleteCol != null && colNames.contains(softDeleteCol)) {
    effectiveSoftDelete = softDeleteCol;
    if (!showDeleted) {
      parts.add('${quoteIdent(softDeleteCol)} IS NULL');
    }
  }

  // Metadata `display.defaultFilter`: a fixed SQL predicate written by
  // whoever maintains the metadata, applied like the soft-delete filter.
  String? defaultFilterApplied;
  if (defaultFilter != null && defaultFilter.trim().isNotEmpty) {
    parts.add('(${defaultFilter.trim()})');
    defaultFilterApplied = defaultFilter.trim();
  }

  return _ComposedWhere(
    where: parts.isEmpty ? null : parts.join(' AND '),
    params: params,
    effectiveSoftDeleteColumn: effectiveSoftDelete,
    tenantFilterApplied: tenantApplied,
    defaultFilterApplied: defaultFilterApplied,
  );
}

class QueryRunner {
  QueryRunner(this.conn);
  final DbExecutor conn;

  static const maxRows = 10000;

  Future<QueryRunResult> runSql(
    String sql, {
    CancelToken? cancelToken,
    Map<String, Object?>? named,
    bool readOnly = false,
  }) async {
    var trimmed = sql.trim();
    if (trimmed.endsWith(';')) {
      trimmed = trimmed.substring(0, trimmed.length - 1).trim();
    }
    if (trimmed.isEmpty) {
      throw const FormatException('Empty query.');
    }
    if (containsMultipleStatements(trimmed)) {
      throw const FormatException(
        'Run one statement at a time (phase 1 limitation).',
      );
    }

    final stopwatch = Stopwatch()..start();
    // Metadata-defined SQL runs fenced into a read-only transaction.
    final result = readOnly
        ? await executeReadOnly(
            conn,
            trimmed,
            named: named,
            cancelToken: cancelToken,
          )
        : named == null || named.isEmpty
        ? await conn.execute(trimmed, cancelToken: cancelToken)
        : await conn.execute(trimmed, named: named, cancelToken: cancelToken);
    stopwatch.stop();
    if (cancelToken?.isCancelled ?? false) {
      throw const _CancelledException();
    }

    final specs = <GridColumnSpec>[
      for (final c in result.columns)
        gridColumn(
          name: c.name,
          type: pgTypeFromTypeName(c.typeName),
          typeName: c.typeName ?? '',
        ),
    ];

    final rows = <List<Object?>>[];
    var truncated = false;
    for (final row in result.rows) {
      if (rows.length >= maxRows) {
        truncated = true;
        break;
      }
      rows.add(row);
    }

    return QueryRunResult(
      data: GridData(columns: specs, rows: rows),
      elapsed: stopwatch.elapsed,
      truncated: truncated,
    );
  }
}

class _CancelledException implements Exception {
  const _CancelledException();
  @override
  String toString() => 'Query cancelled';
}

/// Applies per-column access to a query result: `none` columns are dropped,
/// masked ones show [MaskedValue]. Used for named queries (whose result
/// columns are addressable as `query:<id>.<col>`) and for action queries
/// (best effort, by column name against the action's table).
QueryRunResult applyColumnAccess(
  QueryRunResult result,
  AccessDecision Function(String column) decide,
) {
  final columns = result.data.columns;
  final keep = <int>[];
  final masked = <int>{};
  for (var i = 0; i < columns.length; i++) {
    final decision = decide(columns[i].name);
    if (decision.isNone) continue;
    if (decision.isMasked) masked.add(keep.length);
    keep.add(i);
  }
  if (keep.length == columns.length && masked.isEmpty) return result;
  final rows = [
    for (final row in result.data.rows) [for (final i in keep) row[i]],
  ];
  return QueryRunResult(
    data: GridData(
      columns: [for (final i in keep) columns[i]],
      rows: maskRows(rows, masked),
    ),
    elapsed: result.elapsed,
    truncated: result.truncated,
  );
}
