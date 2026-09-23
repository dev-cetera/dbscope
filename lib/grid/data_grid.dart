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
import '../shell/app_state.dart';
import 'grid_data.dart';
import 'pg_grid_adapters.dart';

export 'grid_data.dart';

class DataGrid extends StatefulWidget {
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
  final void Function(ForeignKey fk, bool incoming)? onFollowLink;

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
  });

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
      final v = AppState.instance.rowHeight;
      if (v != _rowHeight.value) _rowHeight.value = v;
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
      for (final fk in widget.foreignKeys) {
        if (fk.fromSchema == widget.schema && fk.fromTable == widget.table) {
          outboundGroups.putIfAbsent(fk.constraintKey, () => []).add(fk);
        }
        if (fk.toSchema == widget.schema && fk.toTable == widget.table) {
          inboundByColumn.putIfAbsent(fk.toColumn, () => []).add(fk);
        }
      }
      for (final entry in outboundGroups.entries) {
        if (entry.value.length == 1) {
          outboundByColumn[entry.value.first.fromColumn] = entry.value.first;
        }
      }
    }

    final policies = <String, EditPolicy>{
      for (final p in widget.editPolicies) p.column: p,
    };

    // Defaults stored on the column spec so the package's reset logic
    // picks them up without re-passing the type table.
    final columnsWithWidths = <GridColumnSpec>[
      for (final c in widget.data.columns)
        gridColumn(
          name: c.name,
          type: c.type ?? PgType.unknown,
          typeName: c.typeLabel,
          primaryKey: c.primaryKey,
          indexed: c.indexed,
          defaultWidth:
              c.defaultWidth ?? defaultWidthForPgType(c.type ?? PgType.unknown),
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
    );
  }
}
