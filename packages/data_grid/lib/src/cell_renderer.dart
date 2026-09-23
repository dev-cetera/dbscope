import 'package:flutter/widgets.dart';

import 'grid_data.dart';

/// Context passed to a [CellRenderer] when the grid asks it to render
/// a non-editing cell. [value] is `data.rows[rowIdx][originalIdx]` —
/// the renderer decides how to format it.
class CellRenderContext<TypeTag> {
  /// Raw cell value, exactly as the caller put it in `GridData.rows`.
  final Object? value;

  /// The column this cell belongs to.
  final GridColumnSpec<TypeTag> column;

  /// Whether the cell is part of the current selection range.
  final bool isSelected;

  /// True when this is the focused cell (the cursor — at most one
  /// cell has it). Always implies [isSelected].
  final bool isFocused;

  /// Whether the cell is in an editable column (i.e. the caller has
  /// supplied a [CellEditor] for it). Renderers can use this to draw
  /// a subtle editable affordance.
  final bool isEditable;

  /// Cached row index in the underlying matrix.
  final int rowIdx;

  /// Cached original column index in the underlying matrix.
  final int originalIdx;

  const CellRenderContext({
    required this.value,
    required this.column,
    required this.isSelected,
    required this.isFocused,
    required this.isEditable,
    required this.rowIdx,
    required this.originalIdx,
  });
}

/// Hook for rendering one cell's content. The grid handles selection
/// backgrounds, borders and editor swapping; this only renders the
/// inner content widget.
abstract class CellRenderer<TypeTag> {
  const CellRenderer();
  Widget build(BuildContext context, CellRenderContext<TypeTag> ctx);
}

/// Boring default: renders [value]`.toString()` as plain text. Useful
/// as a fallback when no type-specific renderer is needed.
class DefaultCellRenderer<TypeTag> extends CellRenderer<TypeTag> {
  const DefaultCellRenderer();

  @override
  Widget build(BuildContext context, CellRenderContext<TypeTag> ctx) {
    final v = ctx.value;
    if (v == null) {
      return const Text(
        'NULL',
        style: TextStyle(fontStyle: FontStyle.italic),
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text(v.toString(), overflow: TextOverflow.ellipsis);
  }
}
