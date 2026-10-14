// The one place an EditPolicy list is built for a table: the grid, the
// Navigator's row list and row detail, and the Linked view's cards all use
// it, so a column that access control or metadata makes read-only is
// read-only everywhere.

import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../meta/access_policy.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import 'edit_policy.dart';
import 'executor.dart';

List<EditPolicy> buildEditPolicies({
  required DbExecutor conn,
  required String schema,
  required String table,
  required List<ColumnInfo> columns,
  required List<String> pkColumns,
  bool connectionReadOnly = false,
}) {
  final snapshot = MetadataCache.instance.snapshotForExecutor(conn);
  final access = snapshot?.policy ?? AccessPolicy.unrestricted;
  final index = snapshot?.index;
  final tableAccess = access.forTable(schema, table);
  final tablePolicy = index?.policyTable(schema, table);
  // `touch` stamps CURRENT_TIMESTAMP, so only time-typed columns qualify — an
  // epoch-integer or text column would fail every edit (or get garbage).
  final timeColumns = {
    for (final column in columns)
      if (column.type == PgType.timestamp ||
          column.type == PgType.timestamptz ||
          column.type == PgType.date)
        column.name,
  };
  final pkMasked = columns.any(
    (column) => column.isMasked && pkColumns.contains(column.name),
  );
  final tableEditable =
      tableAccess.level.atLeast(AccessLevel.edit) &&
      !pkMasked &&
      !(tablePolicy?.readOnly ?? false);

  return [
    for (final column in columns)
      _policyFor(
        column,
        schema: schema,
        table: table,
        pkColumns: pkColumns,
        connectionReadOnly: connectionReadOnly,
        tableAccess: tableAccess,
        tableEditable: tableEditable,
        pkMasked: pkMasked,
        tablePolicy: tablePolicy,
        columnPolicy: index?.policyColumn(schema, table, column.name),
        touchColumns: [
          for (final touchColumn in tablePolicy?.touch ?? const <String>[])
            if (timeColumns.contains(touchColumn)) touchColumn,
        ],
      ),
  ];
}

EditPolicy _policyFor(
  ColumnInfo column, {
  required String schema,
  required String table,
  required List<String> pkColumns,
  required bool connectionReadOnly,
  required AccessDecision tableAccess,
  required bool tableEditable,
  required bool pkMasked,
  required PolicySpec? tablePolicy,
  required PolicySpec? columnPolicy,
  required List<String> touchColumns,
}) {
  String? reason;
  if (!tableEditable) {
    if (pkMasked) {
      reason = 'The primary key is masked for you, so rows cannot be edited.';
    } else if (tablePolicy?.readOnly ?? false) {
      reason = tablePolicy?.reason ?? 'Metadata marks this table read-only.';
    } else {
      reason = 'Your access to this table is ${tableAccess.level.name}.';
    }
  } else if (!column.accessLevel.atLeast(AccessLevel.edit)) {
    reason = 'Your access to this column is ${column.accessLevel.name}.';
  } else if (columnPolicy?.readOnly ?? false) {
    reason = columnPolicy?.reason ?? 'Metadata marks this column read-only.';
  }
  return EditPolicy(
    schema: schema,
    table: table,
    pkColumns: pkColumns,
    column: column.name,
    type: column.type,
    typeName: column.typeName,
    nullable: column.nullable,
    isGenerated: column.isGenerated,
    isIdentity: column.isIdentity,
    readOnly:
        pkColumns.isEmpty ||
        column.isGenerated ||
        column.isIdentity ||
        connectionReadOnly ||
        reason != null,
    multiLine:
        column.type == PgType.json ||
        column.type == PgType.jsonb ||
        column.type == PgType.text,
    nullIfBlank: column.nullable,
    enumValues: column.enumValues,
    readOnlyReason: reason,
    pattern: columnPolicy?.pattern,
    min: columnPolicy?.min,
    max: columnPolicy?.max,
    touchColumns: touchColumns,
  );
}
