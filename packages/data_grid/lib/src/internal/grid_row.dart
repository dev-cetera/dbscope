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
  final int rowIdx;
  final List<Object?> values;
  final GridData<TypeTag> data;
  final GridModel model;
  final GridStyle style;
  final CellRenderer<TypeTag> renderer;
  final CellEditor<TypeTag>? editor;
  final CellOverlayProvider<TypeTag>? overlay;
  final double rowHeight;

  final void Function(int row, int column, {required bool extend}) onCellTap;
  final void Function(int row, int column) onCellDoubleTap;
  final void Function(int row, int column, Object? newValue) onCommit;
  final void Function() onCancelEdit;

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[];
    final selection = model.selection;
    final editingRow = model.editingRow;
    final editingColumn = model.editingCol;

    for (var viewIndex = 0; viewIndex < model.order.length; viewIndex++) {
      final originalIndex = model.viewToOriginal(viewIndex);
      final column = data.columns[originalIndex];
      final value = originalIndex < values.length ? values[originalIndex] : null;
      final isSelected = selection?.contains(rowIdx, viewIndex) ?? false;
      final isFocused =
          selection != null && selection.focusRow == rowIdx && selection.focusCol == viewIndex;
      final isEditing = editingRow == rowIdx && editingColumn == viewIndex;
      cells.add(
        GridCell<TypeTag>(
          value: value,
          rowIdx: rowIdx,
          originalIdx: originalIndex,
          column: column,
          renderer: renderer,
          editor: editor,
          overlay: overlay,
          style: style,
          isSelected: isSelected,
          isFocused: isFocused,
          isEditing: isEditing,
          width: model.widthAt(viewIndex),
          height: rowHeight,
          onTap: () => onCellTap(rowIdx, viewIndex, extend: _isShiftPressed()),
          onDoubleTap:
              (editor?.canEdit(column) ?? false) ? () => onCellDoubleTap(rowIdx, viewIndex) : null,
          onCommit: (newValue) => onCommit(rowIdx, viewIndex, newValue),
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
