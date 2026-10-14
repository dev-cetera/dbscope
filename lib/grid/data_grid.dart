// Powerdb's data grid widget — a thin Postgres-aware wrapper over the
// generic `data_grid` package. The package owns the grid mechanics
// (selection, reorder, edit lifecycle, TSV/CSV copy, controller); this
// file wires in PgType + EditPolicy + ForeignKey + AppPalette.
//
// Public API (DataGrid, DataGridController, GridData, GridColumnSpec,
// GridEditEvent, GridSortEvent, GridViewMode) preserves the names the
// rest of the app already uses.

import 'package:data_grid/data_grid.dart' as g;
import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../db/edit_policy.dart';
import '../meta/meta_models.dart';
import '../shell/app_state.dart';
import 'grid_data.dart';
import 'pg_grid_adapters.dart';

export 'grid_data.dart';

class DataGrid extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.data,
    this.isLoading = false,
    this.error,
    this.editPolicies = const [],
    this.controller,
    this.onCellEdit,
    this.onSort,
    this.onDeleteRow,
    this.onOpenDetail,
    this.onRowSelected,
    this.onLoadMore,
    this.hasMore = false,
    this.viewMode = GridViewMode.typed,
    this.foreignKeys = const [],
    this.schema,
    this.table,
    this.onFollowLink,
    this.contextMenuExtras,
    this.headerBuilder,
    this.displayByColumn = const {},
  });
  final GridData data;
  final bool isLoading;
  final String? error;
  final List<EditPolicy> editPolicies;
  final g.DataGridController<PgType>? controller;
  final void Function(g.GridEditEvent event)? onCellEdit;
  final void Function(g.GridSortEvent event)? onSort;
  final void Function(int rowIdx)? onDeleteRow;
  final void Function(int rowIdx)? onOpenDetail;
  final void Function(int? rowIdx)? onRowSelected;
  final VoidCallback? onLoadMore;
  final bool hasMore;
  final GridViewMode viewMode;

  final List<ForeignKey> foreignKeys;
  final String? schema;
  final String? table;
  final void Function(ForeignKey foreignKey, {required bool incoming})?
  onFollowLink;

  /// Extra right-click entries for the clicked cell (row index, original
  /// column index) — metadata actions, links, "About this column", …
  final List<GridMenuEntry> Function(
    int rowIdx,
    int columnIndex,
    List<int> selectedRows,
  )?
  contextMenuExtras;

  /// Wraps each column header (original column index): description
  /// tooltip, right-click "About this column".
  final Widget Function(BuildContext context, int columnIndex, Widget header)?
  headerBuilder;

  /// Metadata display (value renderers) by column name.
  final Map<String, DisplaySpec> displayByColumn;

  @override
  State<DataGrid> createState() => _DataGridState();
}

class _DataGridState extends State<DataGrid> {
  late final ValueNotifier<double> _rowHeight;
  late final VoidCallback _appStateListener;

  @override
  void initState() {
    super.initState();
    _rowHeight = ValueNotifier<double>(AppState.instance.rowHeight);
    _appStateListener = () {
      final rowHeight = AppState.instance.rowHeight;
      if (rowHeight != _rowHeight.value) _rowHeight.value = rowHeight;
    };
    AppState.instance.addListener(_appStateListener);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_appStateListener);
    _rowHeight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final outboundByColumn = <String, ForeignKey>{};
    final inboundByColumn = <String, List<ForeignKey>>{};
    if (widget.schema != null && widget.table != null) {
      // Group outbound FKs by constraint so composite FKs don't
      // misrender as a per-cell single link.
      final outboundGroups = <String, List<ForeignKey>>{};
      for (final foreignKey in widget.foreignKeys) {
        if (foreignKey.fromSchema == widget.schema &&
            foreignKey.fromTable == widget.table) {
          outboundGroups
              .putIfAbsent(foreignKey.constraintKey, () => [])
              .add(foreignKey);
        }
        if (foreignKey.toSchema == widget.schema &&
            foreignKey.toTable == widget.table) {
          inboundByColumn
              .putIfAbsent(foreignKey.toColumn, () => [])
              .add(foreignKey);
        }
      }
      for (final entry in outboundGroups.entries) {
        if (entry.value.length == 1) {
          outboundByColumn[entry.value.first.fromColumn] = entry.value.first;
        }
      }
    }

    final policies = <String, EditPolicy>{
      for (final policy in widget.editPolicies) policy.column: policy,
    };

    // Defaults stored on the column spec so the package's reset logic
    // picks them up without re-passing the type table.
    final columnsWithWidths = <GridColumnSpec>[
      for (final column in widget.data.columns)
        gridColumn(
          name: column.name,
          type: column.type ?? PgType.unknown,
          typeName: column.typeLabel,
          primaryKey: column.primaryKey,
          indexed: column.indexed,
          defaultWidth:
              column.defaultWidth ??
              defaultWidthForPgType(column.type ?? PgType.unknown),
          hidden: column.hidden,
          tooltip: column.tooltip,
          marker: column.marker,
        ),
    ];
    final dataForGrid = g.GridData<PgType>(
      columns: columnsWithWidths,
      rows: widget.data.rows,
    );

    final palette = AppPalette.of(context);
    return g.DataGrid<PgType>(
      data: dataForGrid,
      isLoading: widget.isLoading,
      error: widget.error,
      controller: widget.controller,
      cellRenderer: PgTypeCellRenderer(
        outboundByColumn: outboundByColumn,
        inboundByColumn: inboundByColumn,
        onFollowLink: widget.onFollowLink,
        viewMode: widget.viewMode,
        displayByColumn: widget.displayByColumn,
      ),
      cellEditor: EditPolicyCellEditor(policies),
      style: gridStyleFromPalette(palette),
      rowHeight: _rowHeight,
      onLoadMore: widget.onLoadMore,
      hasMore: widget.hasMore,
      onCellEdit: widget.onCellEdit,
      onSort: widget.onSort,
      onDeleteRow: widget.onDeleteRow,
      onOpenDetail: widget.onOpenDetail,
      onRowSelected: widget.onRowSelected,
      contextMenuExtras: widget.contextMenuExtras,
      headerBuilder: widget.headerBuilder,
    );
  }
}
