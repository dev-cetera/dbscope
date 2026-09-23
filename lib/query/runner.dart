import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../connection/profile.dart';
import '../db/executor.dart';
import '../grid/data_grid.dart';
import '../db/edit_policy.dart';
import '../util/sql_parse.dart';
import '../util/sql_quote.dart';
import 'cancel_token.dart';
import 'pager.dart';

class QueryRunResult {
  final GridData data;
  final Duration elapsed;
  final bool truncated;

  const QueryRunResult({
    required this.data,
    required this.elapsed,
    this.truncated = false,
  });
}

class TableLoadResult {
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
  });

  GridData toGridData() => GridData(
    columns: [
      for (final c in columns)
        gridColumn(name: c.name, type: c.type, typeName: c.typeName),
    ],
    rows: firstRows,
  );
}

class TableLoader {
  final DbExecutor conn;
  final bool connectionReadOnly;
  TableLoader(this.conn, {this.connectionReadOnly = true});

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
  }) async {
    final stopwatch = Stopwatch()..start();
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

    final composed = _composeBaseWhere(
      profile: profile,
      schema: schema,
      table: table,
      columns: columns,
      showDeleted: showDeleted,
      callerWhere: baseWhere,
      callerParams: baseWhereParams,
    );

    final pager = KeysetPager(
      conn: conn,
      schema: schema,
      table: table,
      columns: columns,
      pkColumns: pk,
      sortColumn: sortColumn,
      descending: descending,
      pageSize: pageSize,
      baseWhere: composed.where,
      baseWhereParams: composed.params,
    );
    final first = await pager.fetchNext(cancelToken: cancelToken);
    stopwatch.stop();

    final policies = [
      for (final c in columns)
        EditPolicy(
          schema: schema,
          table: table,
          pkColumns: pk,
          column: c.name,
          type: c.type,
          typeName: c.typeName,
          nullable: c.nullable,
          isGenerated: c.isGenerated,
          isIdentity: c.isIdentity,
          readOnly:
              pk.isEmpty || c.isGenerated || c.isIdentity || connectionReadOnly,
          multiLine:
              c.type == PgType.json ||
              c.type == PgType.jsonb ||
              c.type == PgType.text,
          nullIfBlank: c.nullable,
          enumValues: c.enumValues,
        ),
    ];

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
    );
  }
}

class _ComposedWhere {
  final String? where;
  final List<Object?> params;
  final String? effectiveSoftDeleteColumn;
  final bool tenantFilterApplied;
  const _ComposedWhere({
    required this.where,
    required this.params,
    required this.effectiveSoftDeleteColumn,
    required this.tenantFilterApplied,
  });
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
    parts.add(callerWhere);
  }

  var tenantApplied = false;
  final tenant = profile?.tenantFilter;
  if (tenant != null && colNames.contains(tenant.column)) {
    params.add(tenant.value);
    parts.add('${quoteIdent(tenant.column)} = \$${params.length}');
    tenantApplied = true;
  }

  String? effectiveSoftDelete;
  final overrides = profile?.overridesFor(schema, table);
  final softDeleteCol = overrides?.softDeleteColumn;
  if (softDeleteCol != null && colNames.contains(softDeleteCol)) {
    effectiveSoftDelete = softDeleteCol;
    if (!showDeleted) {
      parts.add('${quoteIdent(softDeleteCol)} IS NULL');
    }
  }

  return _ComposedWhere(
    where: parts.isEmpty ? null : parts.join(' AND '),
    params: params,
    effectiveSoftDeleteColumn: effectiveSoftDelete,
    tenantFilterApplied: tenantApplied,
  );
}

class QueryRunner {
  final DbExecutor conn;
  QueryRunner(this.conn);

  static const int maxRows = 10000;

  Future<QueryRunResult> runSql(String sql, {CancelToken? cancelToken}) async {
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
    final result = await conn.execute(trimmed, cancelToken: cancelToken);
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
