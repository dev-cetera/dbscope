import 'package:flutter/widgets.dart';

import 'grid_data.dart';

/// Context passed to a [CellEditor] when the grid enters edit mode on
/// a cell. The editor is expected to render an inline input sized to
/// the cell and report every change through [onChanged]; the grid commits
/// the latest value on Enter / Tab or when another cell is clicked, and
/// discards it on Esc.
class CellEditContext<TypeTag> {
  const CellEditContext({
    required this.value,
    required this.column,
    required this.onChanged,
    required this.onCommit,
    required this.onCancel,
    required this.focusNode,
    required this.compact,
  });
  final Object? value;
  final GridColumnSpec<TypeTag> column;

  /// Call on every change with the parsed in-progress value. Does not end
  /// the edit.
  final ValueChanged<Object?> onChanged;

  /// Call with the parsed new value to confirm the edit at once.
  final void Function(Object? newValue) onCommit;

  /// Call to discard the edit (revert the cell).
  final VoidCallback onCancel;

  /// Focus node managed by the grid; editors that take keyboard input
  /// must attach it to their input so the grid can focus it on
  /// edit-begin. Otherwise typing goes nowhere until the user clicks the
  /// input.
  final FocusNode focusNode;

  /// Whether the grid will render in a one-row-tall slot. Editors
  /// should hide multi-line affordances if true.
  final bool compact;
}

/// Hook for editing one cell. Returning null means this cell is not
/// editable — the grid will not enter edit mode on it.
abstract class CellEditor<TypeTag> {
  const CellEditor();

  /// Whether [column]'s cells can ever be edited. The grid uses this
  /// for the double-tap / Enter affordance check before constructing
  /// a context.
  bool canEdit(GridColumnSpec<TypeTag> column);

  /// Build the inline input. Called only when [canEdit] returned
  /// true. Return any widget — the grid wraps it in keyboard shortcut
  /// handlers for Enter / Tab / Esc.
  Widget build(BuildContext context, CellEditContext<TypeTag> editContext);

  /// Optional hook: when the grid wants to commit a value that came
  /// from outside the editor (e.g. via the keyboard), it asks the
  /// editor to canonicalise it first (e.g. compact JSON, parse number).
  /// Default: return the value unchanged.
  Object? canonicalize(Object? raw, GridColumnSpec<TypeTag> column) => raw;

  /// True if this column needs to be edited in a modal dialog rather
  /// than inline (e.g. multi-line JSON in a 32 px row). When true the
  /// grid skips inline edit-mode and calls [openDialog] instead.
  bool requiresDialog(GridColumnSpec<TypeTag> column) => false;

  /// Opens a modal editor; returns the new value or null on cancel.
  /// Only called when [requiresDialog] returns true.
  Future<Object?> openDialog(
    BuildContext context,
    Object? currentValue,
    GridColumnSpec<TypeTag> column,
  ) async {
    return null;
  }
}
