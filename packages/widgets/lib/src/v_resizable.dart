import 'package:flutter/material.dart';

enum VResizeSide { top, bottom }

/// Vertically resizable container. Wraps [child] in a `SizedBox` of
/// [height] with a thin horizontal drag handle on the [side] edge.
/// Dragging resizes it live and [onResized] reports the final height
/// once, when the drag ends. See `Resizable` for why.
class VResizable extends StatefulWidget {
  const VResizable({
    super.key,
    required this.height,
    required this.onResized,
    required this.child,
    this.minHeight = 80,
    this.maxHeight = 2000,
    this.side = VResizeSide.bottom,
  });
  final double height;
  final double minHeight;
  final double maxHeight;
  final VResizeSide side;
  final ValueChanged<double> onResized;
  final Widget child;

  @override
  State<VResizable> createState() => _VResizableState();
}

class _VResizableState extends State<VResizable> {
  /// Height of the drag in progress; null when no drag is running.
  double? _dragHeight;

  void _endDrag() {
    final height = _dragHeight;
    if (height == null) return;
    setState(() => _dragHeight = null);
    if (height != widget.height) widget.onResized(height);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handle = MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) => setState(() => _dragHeight = widget.height),
        onVerticalDragUpdate: (details) {
          final delta = widget.side == VResizeSide.bottom ? details.delta.dy : -details.delta.dy;
          final next = ((_dragHeight ?? widget.height) + delta).clamp(
            widget.minHeight,
            widget.maxHeight,
          );
          if (next != _dragHeight) setState(() => _dragHeight = next);
        },
        onVerticalDragEnd: (_) => _endDrag(),
        onVerticalDragCancel: _endDrag,
        child: Container(
          height: 5.0,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(height: 1.0, color: theme.dividerColor),
        ),
      ),
    );
    return SizedBox(
      height: _dragHeight ?? widget.height,
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
