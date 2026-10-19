// The one place the row-level write rules for a table are decided: may this
// viewer insert or delete here, and how does a delete happen (soft or hard)?
// The table view, the Navigator's row list and row detail all ask this, so
// a rule (access level, metadata `danger`, soft-delete column, masked key)
// can't hold in one view and not another.

import '../catalog/schema_catalog.dart';
import '../connection/profile.dart';
import '../meta/access_policy.dart';
import '../meta/masked_value.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../util/sql_quote.dart';
import 'executor.dart';

class TableWriteRules {
  const TableWriteRules({
    required this.access,
    required this.softDeleteColumn,
    required this.deleteRefusal,
    required this.hardDeleteRefusal,
    required this.returningList,
  });
  final AccessDecision access;

  /// Soft-delete column that exists on the table, or null for hard deletes.
  final String? softDeleteColumn;

  /// Metadata `danger: delete` — every delete refused, with this message.
  final String? deleteRefusal;

  /// Metadata `danger: hardDelete` — only hard deletes refused.
  final String? hardDeleteRefusal;

  /// `INSERT … RETURNING` list: no `none` columns, masked ones as NULL.
  final String returningList;

  /// Null when a row with these key values may be deleted; else why not.
  String? whyNoDelete({
    required List<String> pkColumns,
    required Map<String, Object?> pkValues,
  }) {
    if (pkColumns.isEmpty) return 'Cannot delete: table has no primary key.';
    if (pkValues.values.any((value) => value is MaskedValue)) {
      return 'The primary key is masked for you, so rows cannot be deleted.';
    }
    if (!access.level.atLeast(AccessLevel.full)) {
      return 'Your access to this table is ${access.level.name}; deleting '
          'needs full.';
    }
    if (deleteRefusal != null) return deleteRefusal;
    if (softDeleteColumn == null && hardDeleteRefusal != null) {
      return hardDeleteRefusal;
    }
    return null;
  }

  /// Null when this viewer may insert here; else why not. (A table without
  /// a primary key can still take inserts; callers that need a key check
  /// for it themselves.)
  String? whyNoInsert({required List<String> pkColumns}) {
    if (!access.level.atLeast(AccessLevel.full)) {
      return 'Your access to this table is ${access.level.name}; inserting '
          'needs full.';
    }
    return null;
  }
}

/// Write rules for [schema].[table]. [columns] are the (access-filtered)
/// catalog columns; [profile] supplies the machine's soft-delete override
/// (it wins over metadata, as everywhere else).
TableWriteRules writeRulesFor(
  DbExecutor conn, {
  required String schema,
  required String table,
  required List<ColumnInfo> columns,
  required List<String> pkColumns,
  ConnectionProfile? profile,
}) {
  final snapshot = MetadataCache.instance.snapshotForExecutor(conn);
  final policy = snapshot?.policy ?? AccessPolicy.unrestricted;
  final tablePolicy = snapshot?.index.policyTable(schema, table);
  final names = {for (final column in columns) column.name};
  final softDelete =
      profile?.overridesFor(schema, table).softDeleteColumn ?? tablePolicy?.softDelete;
  return TableWriteRules(
    access: policy.forTable(schema, table),
    softDeleteColumn: softDelete != null && names.contains(softDelete) ? softDelete : null,
    deleteRefusal: (tablePolicy?.forbidsAnyDelete ?? false)
        ? (tablePolicy?.message ?? 'Metadata forbids deleting rows here.')
        : null,
    hardDeleteRefusal: (tablePolicy?.forbidsHardDelete ?? false)
        ? (tablePolicy?.message ?? 'Metadata forbids hard deletes on this table.')
        : null,
    returningList: columns.isEmpty
        ? '*'
        : [
            for (final column in columns)
              if (column.isMasked && !pkColumns.contains(column.name))
                'NULL AS ${quoteIdent(column.name)}'
              else
                quoteIdent(column.name),
          ].join(', '),
  );
}
