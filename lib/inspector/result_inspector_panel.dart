import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../catalog/schema_catalog.dart';
import '../db/edit_policy.dart';
import '../grid/data_grid.dart';
import '../shell/app_state.dart';
import 'property_inspector.dart';

/// Right-side row inspector for any grid result.
///
/// For [TableTab] the caller passes full catalog metadata (columns,
/// edit policies, FKs) so fields are typed, editable, and show FK chips.
/// For [QueryTab] the metadata is unknown — pass empty
/// lists and the panel renders the row read-only, synthesising minimal
/// [ColumnInfo] entries from whatever [GridColumnSpec] info the result
/// already carries.
class ResultInspectorPanel extends StatelessWidget {
  const ResultInspectorPanel({
    super.key,
    required this.data,
    required this.selectedRowIndex,
    this.schema,
    this.table,
    this.catalogColumns = const [],
    this.editPolicies = const [],
    this.pkColumns = const [],
    this.foreignKeys = const [],
    this.connectionId,
    this.onSave,
    this.onFollowLink,
  });
  final String? schema;
  final String? table;
  final GridData? data;
  final int? selectedRowIndex;
  final List<ColumnInfo> catalogColumns;
  final List<EditPolicy> editPolicies;
  final List<String> pkColumns;
  final List<ForeignKey> foreignKeys;
  final String? connectionId;
  final Future<void> Function(EditPolicy, Object?)? onSave;
  final void Function(ForeignKey foreignKey, {required bool incoming})? onFollowLink;

  static Future<void> _noopSave(EditPolicy _, Object? _) async {}

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = this.data;
    final rowIndex = selectedRowIndex;

    // Use the catalog metadata when present; otherwise synthesise a
    // minimal ColumnInfo per grid column so PropertyInspector can render.
    final columns = catalogColumns.isNotEmpty
        ? catalogColumns
        : (data == null
              ? const <ColumnInfo>[]
              : [
                  for (final column in data.columns)
                    ColumnInfo(
                      name: column.name,
                      type: column.pgType,
                      typeName: column.typeName,
                      nullable: true,
                      defaultExpr: null,
                      isGenerated: false,
                      isIdentity: false,
                    ),
                ]);

    final hasRow =
        data != null &&
        rowIndex != null &&
        rowIndex >= 0 &&
        rowIndex < data.rows.length &&
        columns.isNotEmpty;

    Map<String, Object?>? row;
    if (hasRow) {
      row = {
        for (var i = 0; i < data.columns.length; i++) data.columns[i].name: data.rows[rowIndex][i],
      };
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: AppPanel(
        title: hasRow ? 'Row inspector' : 'Row inspector (no selection)',
        titleIcon: Icons.article_outlined,
        trailing: IconButton(
          tooltip: 'Hide inspector',
          icon: const Icon(Icons.close, size: 14.0),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(2.0),
          constraints: const BoxConstraints(),
          onPressed: AppState.instance.togglePropertyInspector,
        ),
        child: hasRow
            ? PropertyInspector(
                schema: schema ?? '',
                table: table ?? '',
                columns: columns,
                row: row!,
                editPolicies: editPolicies,
                pkColumns: pkColumns,
                foreignKeys: foreignKeys,
                connectionId: connectionId,
                onSave: onSave ?? _noopSave,
                onFollowOutbound: onFollowLink != null
                    ? (column, value, group) => onFollowLink!(group.first, incoming: false)
                    : null,
                onOpenInbound: onFollowLink != null
                    ? (group) => onFollowLink!(group.first, incoming: true)
                    : null,
              )
            : const EmptyState(
                icon: Icons.article_outlined,
                iconSize: 36.0,
                message: 'Click a row in the grid to view its fields here.',
              ),
      ),
    );
  }
}
