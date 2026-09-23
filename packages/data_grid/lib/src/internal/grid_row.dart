import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../cell_editor.dart';
import '../cell_overlay.dart';
import '../cell_renderer.dart';
import '../grid_data.dart';
import '../grid_model.dart';
import '../grid_style.dart';
import 'grid_cell.dart';

class GridBodyRow<TypeTag> extends StatelessWidget {
  final int rowIdx;
  final List<Object?> values;
  final GridData<TypeTag> data;
  final GridModel model;
  final GridStyle style;
  final CellRenderer<TypeTag> renderer;
  final CellEditor<TypeTag>? editor;
  final CellOverlayProvider<TypeTag>? overlay;
  final double rowHeight;

  final void Function(int row, int col, bool extend) onCellTap;
  final void Function(int row, int col) onCellDoubleTap;
  final void Function(int row, int col, Object? newValue) onCommit;
  final void Function() onCancelEdit;

  const GridBodyRow({
    super.key,
    required this.rowIdx,
    required this.values,
    required this.data,
    required this.model,
    required this.style,
    required this.renderer,
    required this.editor,
    required this.overlay,
    required this.rowHeight,
    required this.onCellTap,
    required this.onCellDoubleTap,
    required this.onCommit,
    required this.onCancelEdit,
  });

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[];
    final selection = model.selection;
    final editingRow = model.editingRow;
    final editingCol = model.editingCol;

    for (var v = 0; v < model.order.length; v++) {
      final originalIdx = model.viewToOriginal(v);
      final col = data.columns[originalIdx];
      final value = originalIdx < values.length ? values[originalIdx] : null;
      final isSelected = selection?.contains(rowIdx, v) ?? false;
      final isFocused = selection != null &&
          selection.focusRow == rowIdx &&
          selection.focusCol == v;
      final isEditing = editingRow == rowIdx && editingCol == v;
      cells.add(
        GridCell<TypeTag>(
          value: value,
          rowIdx: rowIdx,
          originalIdx: originalIdx,
          column: col,
          renderer: renderer,
          editor: editor,
          overlay: overlay,
          style: style,
          isSelected: isSelected,
          isFocused: isFocused,
          isEditing: isEditing,
          width: model.widthAt(v),
          height: rowHeight,
          onTap: () => onCellTap(rowIdx, v, _isShiftPressed()),
          onDoubleTap: (editor?.canEdit(col) ?? false)
              ? () => onCellDoubleTap(rowIdx, v)
              : null,
          onCommit: (newValue) => onCommit(rowIdx, v, newValue),
          onCancel: onCancelEdit,
        ),
      );
    }
    return SizedBox(
      height: rowHeight,
      child: Row(children: cells),
    );
  }

  bool _isShiftPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight) ||
        keys.contains(LogicalKeyboardKey.shift);
  }
}
