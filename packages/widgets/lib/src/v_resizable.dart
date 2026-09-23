import 'package:flutter/material.dart';

enum VResizeSide { top, bottom }

/// Vertically resizable container. Wraps [child] in a `SizedBox` of
/// [height] with a thin horizontal drag handle on the [side] edge.
class VResizable extends StatefulWidget {
  final double height;
  final double minHeight;
  final double maxHeight;
  final VResizeSide side;
  final ValueChanged<double> onResized;
  final Widget child;

  const VResizable({
    super.key,
    required this.height,
    required this.onResized,
    required this.child,
    this.minHeight = 80,
    this.maxHeight = 2000,
    this.side = VResizeSide.bottom,
  });

  @override
  State<VResizable> createState() => _VResizableState();
}

class _VResizableState extends State<VResizable> {
  double? _dragHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handle = MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) => _dragHeight = widget.height,
        onVerticalDragUpdate: (details) {
          final delta =
              widget.side == VResizeSide.bottom
                  ? details.delta.dy
                  : -details.delta.dy;
          final next = ((_dragHeight ?? widget.height) + delta).clamp(
            widget.minHeight,
            widget.maxHeight,
          );
          _dragHeight = next;
          if (next != widget.height) widget.onResized(next);
        },
        onVerticalDragEnd: (_) => _dragHeight = null,
        onVerticalDragCancel: () => _dragHeight = null,
        child: Container(
          height: 5,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(height: 1, color: theme.dividerColor),
        ),
      ),
    );
    return SizedBox(
      height: widget.height,
      child: Column(
        children: [
          if (widget.side == VResizeSide.top) handle,
          Expanded(child: widget.child),
          if (widget.side == VResizeSide.bottom) handle,
        ],
      ),
    );
  }
}
