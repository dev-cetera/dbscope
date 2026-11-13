import 'package:flutter/material.dart';

enum ResizeSide { left, right }

/// Wraps [child] in a `SizedBox` of [width] with a thin drag handle on
/// the [side] edge. Dragging resizes it live, clamped to
/// [[minWidth], [maxWidth]], and [onResized] reports the final width
/// once, when the drag ends.
///
/// The parent owns the width (controlled-component pattern); only the
/// width of a drag in progress lives here. Reporting every pointer move
/// instead made each caller notify the whole window, so a drag rebuilt
/// the sidebar, the open tab and the tab strip on every frame.
class Resizable extends StatefulWidget {
  const Resizable({
    super.key,
    required this.width,
    required this.onResized,
    required this.child,
    this.minWidth = 120,
    this.maxWidth = 2000,
    this.side = ResizeSide.right,
  });
  final double width;
  final double minWidth;
  final double maxWidth;
  final ResizeSide side;
  final ValueChanged<double> onResized;
  final Widget child;

  @override
  State<Resizable> createState() => _ResizableState();
}

class _ResizableState extends State<Resizable> {
  /// Width of the drag in progress; null when no drag is running.
  double? _dragWidth;

  void _endDrag() {
    final width = _dragWidth;
    if (width == null) return;
    setState(() => _dragWidth = null);
    if (width != widget.width) widget.onResized(width);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handle = MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _dragWidth = widget.width),
        onHorizontalDragUpdate: (details) {
          final delta = widget.side == ResizeSide.right ? details.delta.dx : -details.delta.dx;
          final next = ((_dragWidth ?? widget.width) + delta).clamp(
            widget.minWidth,
            widget.maxWidth,
          );
          if (next != _dragWidth) setState(() => _dragWidth = next);
        },
        onHorizontalDragEnd: (_) => _endDrag(),
        onHorizontalDragCancel: _endDrag,
        child: Container(
          width: 5.0,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(width: 1.0, color: theme.dividerColor),
        ),
      ),
    );
    return SizedBox(
      width: _dragWidth ?? widget.width,
      child: Row(
        children: [
          if (widget.side == ResizeSide.left) handle,
          Expanded(child: widget.child),
          if (widget.side == ResizeSide.right) handle,
        ],
      ),
    );
  }
}
