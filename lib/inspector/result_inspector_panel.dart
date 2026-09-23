import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../catalog/schema_catalog.dart';
import '../grid/data_grid.dart';
import '../db/edit_policy.dart';
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
  final void Function(ForeignKey fk, bool incoming)? onFollowLink;

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

  static Future<void> _noopSave(EditPolicy _, Object? _) async {}

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = this.data;
    final idx = selectedRowIndex;

    // Use the catalog metadata when present; otherwise synthesise a
    // minimal ColumnInfo per grid column so PropertyInspector can render.
    final cols = catalogColumns.isNotEmpty
        ? catalogColumns
        : (data == null
              ? const <ColumnInfo>[]
              : [
                  for (final c in data.columns)
                    ColumnInfo(
                      name: c.name,
                      type: c.pgType,
                      typeName: c.typeName,
                      nullable: true,
                      defaultExpr: null,
                      isGenerated: false,
                      isIdentity: false,
                    ),
                ]);

    final hasRow =
        data != null &&
        idx != null &&
        idx >= 0 &&
        idx < data.rows.length &&
        cols.isNotEmpty;

    Map<String, Object?>? row;
    if (hasRow) {
      row = {
        for (var i = 0; i < data.columns.length; i++)
          data.columns[i].name: data.rows[idx][i],
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
          icon: const Icon(Icons.close, size: 14),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(2),
          constraints: const BoxConstraints(),
          onPressed: AppState.instance.togglePropertyInspector,
        ),
        child: hasRow
            ? PropertyInspector(
                schema: schema ?? '',
                table: table ?? '',
                columns: cols,
                row: row!,
                editPolicies: editPolicies,
                pkColumns: pkColumns,
                foreignKeys: foreignKeys,
                connectionId: connectionId,
                onSave: onSave ?? _noopSave,
                onFollowOutbound: onFollowLink != null
                    ? (col, value, group) => onFollowLink!(group.first, false)
                    : null,
                onOpenInbound: onFollowLink != null
                    ? (group) => onFollowLink!(group.first, true)
                    : null,
              )
            : const EmptyState(
                icon: Icons.article_outlined,
                iconSize: 36,
                message: 'Click a row in the grid to view its fields here.',
              ),
      ),
    );
  }
}
