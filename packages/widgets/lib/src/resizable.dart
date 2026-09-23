import 'package:flutter/material.dart';

enum ResizeSide { left, right }

/// Wraps [child] in a `SizedBox` of [width] with a thin drag handle on
/// the [side] edge. Dragging the handle calls [onResized] with the new
/// width, clamped to [[minWidth], [maxWidth]].
///
/// The parent owns the width (controlled-component pattern) — this
/// widget never animates or stores width locally so it survives
/// rebuilds without state-loss surprises.
class Resizable extends StatefulWidget {
  final double width;
  final double minWidth;
  final double maxWidth;
  final ResizeSide side;
  final ValueChanged<double> onResized;
  final Widget child;

  const Resizable({
    super.key,
    required this.width,
    required this.onResized,
    required this.child,
    this.minWidth = 120,
    this.maxWidth = 2000,
    this.side = ResizeSide.right,
  });

  @override
  State<Resizable> createState() => _ResizableState();
}

class _ResizableState extends State<Resizable> {
  double? _dragWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handle = MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => _dragWidth = widget.width,
        onHorizontalDragUpdate: (details) {
          final delta =
              widget.side == ResizeSide.right
                  ? details.delta.dx
                  : -details.delta.dx;
          final next = ((_dragWidth ?? widget.width) + delta).clamp(
            widget.minWidth,
            widget.maxWidth,
          );
          _dragWidth = next;
          if (next != widget.width) widget.onResized(next);
        },
        onHorizontalDragEnd: (_) => _dragWidth = null,
        onHorizontalDragCancel: () => _dragWidth = null,
        child: Container(
          width: 5,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(width: 1, color: theme.dividerColor),
        ),
      ),
    );
    return SizedBox(
      width: widget.width,
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
