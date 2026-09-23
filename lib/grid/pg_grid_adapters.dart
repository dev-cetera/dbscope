// Powerdb-specific adapters that turn the generic `data_grid` package
// into the Postgres-aware grid used throughout this app. These wire
// PgType, EditPolicy, ForeignKey overlays, and the AppState row-height
// notifier into the package's pluggable interfaces — see
// `packages/data_grid/lib/data_grid.dart` for the package surface.

import 'package:data_grid/data_grid.dart' as g;
import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../db/edit_policy.dart';
import 'cell_value_display.dart';
import 'grid_data.dart';
import 'inputs/column_input.dart';

/// Cell renderer that delegates to the shared `CellValueDisplay`
/// widget — same code path the property inspector uses, so the email
/// column shows the same thing in both surfaces.
class PgTypeCellRenderer extends g.CellRenderer<PgType> {
  final Map<String, ForeignKey> outboundByColumn;
  final Map<String, List<ForeignKey>> inboundByColumn;
  final void Function(ForeignKey fk, bool incoming)? onFollowLink;
  final GridViewMode viewMode;

  const PgTypeCellRenderer({
    this.outboundByColumn = const {},
    this.inboundByColumn = const {},
    this.onFollowLink,
    this.viewMode = GridViewMode.typed,
  });

  @override
  Widget build(BuildContext context, g.CellRenderContext<PgType> ctx) {
    return CellValueDisplay(
      value: ctx.value,
      pgType: ctx.column.type ?? PgType.unknown,
      columnName: ctx.column.name,
      outboundFk: outboundByColumn[ctx.column.name],
      inboundRefs: inboundByColumn[ctx.column.name] ?? const [],
      onFollowLink: onFollowLink,
      colored: viewMode == GridViewMode.typed,
      detectUrl: viewMode == GridViewMode.typed,
    );
  }
}

/// Cell editor backed by `ColumnInput.forPolicy`. Returns canEdit=false
/// when no [EditPolicy] is supplied for the column or the policy is
/// read-only. JSON columns route through a dialog rather than the
/// inline editor (a multi-line JSON editor would not fit a 32 px row).
class EditPolicyCellEditor extends g.CellEditor<PgType> {
  final Map<String, EditPolicy> policiesByColumn;

  const EditPolicyCellEditor(this.policiesByColumn);

  EditPolicy? _policyFor(String column) => policiesByColumn[column];

  @override
  bool canEdit(g.GridColumnSpec<PgType> column) {
    final policy = _policyFor(column.name);
    return policy != null && !policy.readOnly;
  }

  @override
  bool requiresDialog(g.GridColumnSpec<PgType> column) {
    final t = column.type;
    return t == PgType.json || t == PgType.jsonb;
  }

  @override
  Future<Object?> openDialog(
    BuildContext context,
    Object? currentValue,
    g.GridColumnSpec<PgType> column,
  ) async {
    return showJsonEditorDialog(
      context,
      columnName: column.name,
      currentValue: jsonSourceOf(currentValue),
    );
  }

  @override
  Object? canonicalize(Object? raw, g.GridColumnSpec<PgType> column) {
    final t = column.type;
    if ((t == PgType.json || t == PgType.jsonb) && raw is String) {
      return compactJson(raw);
    }
    return raw;
  }

  @override
  Widget build(BuildContext context, g.CellEditContext<PgType> ctx) {
    final policy = _policyFor(ctx.column.name)!;
    return ColumnInput.forPolicy(
      policy: policy,
      value: ctx.value,
      onChanged: (v) {
        // Track the pending value via the close-over; the grid will
        // canonicalize and commit it via the shortcut handlers.
        ctx.onCommit(v);
      },
      compact: ctx.compact,
    );
  }
}

/// Maps an [AppPalette] into the package's [GridStyle] so the grid
/// matches the Win95 / VS Code Dark chrome the rest of the app uses.
g.GridStyle gridStyleFromPalette(AppPalette palette) {
  return g.GridStyle(
    cellBackground: palette.field,
    selectionBackground: palette.rowHover,
    focusBackground: palette.rowSelected,
    cellBorder: palette.border,
    headerBorderStrong: palette.borderStrong,
    accent: palette.accent,
    accentSoft: palette.accentSoft,
    headerBackground: palette.surfaceRaised,
    textColor: palette.text,
    mutedTextColor: palette.mutedText,
    cellTextStyle: TextStyle(
      color: palette.text,
      fontFamily: palette.uiFontFamily,
      fontSize: palette.smallFontSize,
    ),
    headerTitleStyle: TextStyle(
      color: palette.text,
      fontFamily: palette.uiFontFamily,
      fontSize: palette.smallFontSize,
      fontWeight: FontWeight.bold,
    ),
    headerSubtitleStyle: TextStyle(
      color: palette.mutedText,
      fontFamily: palette.uiFontFamily,
      fontSize: palette.smallFontSize - 1,
    ),
  );
}

/// Default per-PgType column width — keeps narrow types narrow (bool,
/// int4) and gives wide types (uuid, jsonb) room to breathe.
double defaultWidthForPgType(PgType t) {
  switch (t) {
    case PgType.bool_:
      return 80;
    case PgType.int2:
    case PgType.int4:
      return 100;
    case PgType.int8:
    case PgType.numeric:
    case PgType.real:
    case PgType.doublePrecision:
      return 140;
    case PgType.uuid:
      return 280;
    case PgType.date:
      return 120;
    case PgType.time:
      return 120;
    case PgType.timestamp:
    case PgType.timestamptz:
      return 200;
    case PgType.json:
    case PgType.jsonb:
      return 280;
    case PgType.bytea:
      return 160;
    default:
      return 220;
  }
}
