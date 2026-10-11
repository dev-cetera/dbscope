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
    for (final c in columns)
      if (c.type == PgType.timestamp ||
          c.type == PgType.timestamptz ||
          c.type == PgType.date)
        c.name,
  };
  final pkMasked = columns.any(
    (c) => c.isMasked && pkColumns.contains(c.name),
  );
  final tableEditable =
      tableAccess.level.atLeast(AccessLevel.edit) &&
      !pkMasked &&
      !(tablePolicy?.readOnly ?? false);

  return [
    for (final c in columns)
      _policyFor(
        c,
        schema: schema,
        table: table,
        pkColumns: pkColumns,
        connectionReadOnly: connectionReadOnly,
        tableAccess: tableAccess,
        tableEditable: tableEditable,
        pkMasked: pkMasked,
        tablePolicy: tablePolicy,
        columnPolicy: index?.policyColumn(schema, table, c.name),
        touchColumns: [
          for (final t in tablePolicy?.touch ?? const <String>[])
            if (timeColumns.contains(t)) t,
        ],
      ),
  ];
}

EditPolicy _policyFor(
  ColumnInfo c, {
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
  } else if (!c.accessLevel.atLeast(AccessLevel.edit)) {
    reason = 'Your access to this column is ${c.accessLevel.name}.';
  } else if (columnPolicy?.readOnly ?? false) {
    reason = columnPolicy?.reason ?? 'Metadata marks this column read-only.';
  }
  return EditPolicy(
    schema: schema,
    table: table,
    pkColumns: pkColumns,
    column: c.name,
    type: c.type,
    typeName: c.typeName,
    nullable: c.nullable,
    isGenerated: c.isGenerated,
    isIdentity: c.isIdentity,
    readOnly:
        pkColumns.isEmpty ||
        c.isGenerated ||
        c.isIdentity ||
        connectionReadOnly ||
        reason != null,
    multiLine:
        c.type == PgType.json ||
        c.type == PgType.jsonb ||
        c.type == PgType.text,
    nullIfBlank: c.nullable,
    enumValues: c.enumValues,
    readOnlyReason: reason,
    pattern: columnPolicy?.pattern,
    min: columnPolicy?.min,
    max: columnPolicy?.max,
    touchColumns: touchColumns,
  );
}
