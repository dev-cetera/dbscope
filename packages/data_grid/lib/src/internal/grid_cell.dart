import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../cell_editor.dart';
import '../cell_overlay.dart';
import '../cell_renderer.dart';
import '../grid_data.dart';
import '../grid_style.dart';

/// One cell in the body of the grid. Two modes:
/// - Display: delegates to [renderer.build].
/// - Edit: delegates to [editor.build] wrapped in Enter/Tab/Esc
/// shortcuts.
class GridCell<TypeTag> extends StatefulWidget {
  final Object? value;
  final int rowIdx;
  final int originalIdx;
  final GridColumnSpec<TypeTag> column;
  final CellRenderer<TypeTag> renderer;
  final CellEditor<TypeTag>? editor;
  final CellOverlayProvider<TypeTag>? overlay;
  final GridStyle style;
  final bool isSelected;
  final bool isFocused;
  final bool isEditing;
  final double width;
  final double height;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final void Function(Object? newValue)? onCommit;
  final VoidCallback? onCancel;

  const GridCell({
    super.key,
    required this.value,
    required this.rowIdx,
    required this.originalIdx,
    required this.column,
    required this.renderer,
    required this.style,
    required this.isSelected,
    required this.isFocused,
    required this.isEditing,
    required this.width,
    required this.height,
    this.editor,
    this.overlay,
    this.onTap,
    this.onDoubleTap,
    this.onCommit,
    this.onCancel,
  });

  bool get isEditable => editor?.canEdit(column) ?? false;

  @override
  State<GridCell<TypeTag>> createState() => _GridCellState<TypeTag>();
}

class _GridCellState<TypeTag> extends State<GridCell<TypeTag>> {
  Object? _pending;
  final FocusNode _editFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _pending = widget.value;
  }

  @override
  void didUpdateWidget(covariant GridCell<TypeTag> old) {
    super.didUpdateWidget(old);
    if (!widget.isEditing && old.value != widget.value) {
      _pending = widget.value;
    }
    if (widget.isEditing && !old.isEditing) {
      _pending = widget.value;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isEditing) _editFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _editFocus.dispose();
    super.dispose();
  }

  void _commit() {
    final canon =
        widget.editor?.canonicalize(_pending, widget.column) ?? _pending;
    widget.onCommit?.call(canon);
  }

  void _cancel() => widget.onCancel?.call();

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final bg = widget.isFocused
        ? style.focusBackground
        : (widget.isSelected
            ? style.selectionBackground
            : style.cellBackground);
    final border = widget.isFocused
        ? Border.all(color: style.accent, width: 1)
        : Border(
            right: BorderSide(color: style.cellBorder, width: 0.5),
            bottom: BorderSide(color: style.cellBorder, width: 0.5),
          );

    final cellChild =
        widget.isEditing && widget.editor != null ? _editor() : _display();

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.isEditable ? widget.onDoubleTap : null,
        child: Container(
          decoration: BoxDecoration(color: bg, border: border),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          child: cellChild,
        ),
      ),
    );
  }

  Widget _display() {
    final content = widget.renderer.build(
      context,
      CellRenderContext<TypeTag>(
        value: widget.value,
        column: widget.column,
        isSelected: widget.isSelected,
        isFocused: widget.isFocused,
        isEditable: widget.isEditable,
        rowIdx: widget.rowIdx,
        originalIdx: widget.originalIdx,
      ),
    );
    final overlayWidget = widget.overlay?.build(
      context,
      CellOverlayContext<TypeTag>(
        rowIdx: widget.rowIdx,
        originalIdx: widget.originalIdx,
        column: widget.column,
        value: widget.value,
      ),
    );
    if (overlayWidget == null) return content;
    return Stack(
      fit: StackFit.passthrough,
      children: [content, overlayWidget],
    );
  }

  Widget _editor() {
    final editor = widget.editor!;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter): _commit,
        const SingleActivator(LogicalKeyboardKey.tab): _commit,
      },
      child: Focus(
        focusNode: _editFocus,
        child: editor.build(
          context,
          CellEditContext<TypeTag>(
            value: _pending,
            column: widget.column,
            onCommit: (v) {
              _pending = v;
              _commit();
            },
            onCancel: _cancel,
            focusNode: _editFocus,
            compact: true,
          ),
        ),
      ),
    );
  }
}
