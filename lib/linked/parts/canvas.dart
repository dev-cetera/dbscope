part of '../linked_view.dart';

/// Canvas: hosts the node Stack, applies pan/zoom locally during gestures
/// so per-frame drag doesn't trigger an app-wide rebuild. Drag deltas only
/// commit to LinkedTab + notify AppState on drag-end.
class _Canvas extends StatefulWidget {
  final LinkedTab tab;

  /// Called when a row node first mounts so the view can kick off the
  /// catalog + row load. The _NodeShell forwards this through.
  final void Function(LinkedRowNode node) onRowNodeMounted;

  /// Drill-in action. When the user clicks the SchemaCard's open
  /// button on a row node, this fires with the node so the host can
  /// open the row in a Table tab, the Navigator, the inspector, etc.
  /// null hides the open button.
  final void Function(LinkedRowNode node)? onRowNodeActivate;

  /// Right-click handler. Called with the node and the global pointer
  /// position so the host can show a context menu anchored to the click.
  final void Function(LinkedNode node, Offset globalPos)? onNodeContextMenu;

  const _Canvas({
    required this.tab,
    required this.onRowNodeMounted,
    this.onRowNodeActivate,
    this.onNodeContextMenu,
  });

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> with SingleTickerProviderStateMixin {
  /// Live pan delta accumulated during a background-pan gesture. Added
  /// to `tab.pan` for display; committed on `panEnd`.
  Offset _panDelta = Offset.zero;

  /// Active per-node drag. While set, the node renders at `node.position
  /// + _dragDelta`; on `panEnd` the delta is committed to `node.position`.
  String? _dragNodeId;
  Offset _dragDelta = Offset.zero;

  /// Last-interacted node id. Renders last so it sits on top of the
  /// stack — clicking, dragging, or just touching the header brings the
  /// node forward without changing tab.nodes order.
  String? _topNodeId;

  /// Node ids whose width has already been auto-fitted at least once.
  /// We only auto-grow on first paint; subsequent paints leave the
  /// width alone so a manual resize is sticky.
  final Set<String> _autoSizedOnce = <String>{};

  /// Drives the chevron animation on edges. 0..1, wraps every cycle.
  late final Ticker _ticker;
  double _tickerValue = 0;
  Duration _lastTick = Duration.zero;
  static const Duration _kChevronCycle = Duration(milliseconds: 3500);

  /// Where this canvas's top-left sat inside the window on the previous
  /// frame. See [_anchorViewport].
  Offset? _lastViewportOrigin;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _anchorViewport();
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    final ms = dt.inMicroseconds / Duration.microsecondsPerMillisecond;
    final delta = ms / _kChevronCycle.inMilliseconds;
    setState(() {
      _tickerValue = (_tickerValue + delta) % 1.0;
    });
  }

  /// Keep the nodes pinned to the screen when the viewport's own origin
  /// moves. `tab.pan` is canvas-local, so a node sits at `pan +
  /// position * scale` measured from this widget's top-left; when the
  /// left row-picker panel opens, closes, or is dragged, that top-left
  /// slides and the whole graph slides with it. Shifting the pan by the
  /// inverse holds every node where it is on screen.
  ///
  /// Twin of `_SchemaCanvasState._anchorViewport` in
  /// package:schema_viewer — same reasoning, same ticker-driven hook.
  void _anchorViewport() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final previous = _lastViewportOrigin;
    _lastViewportOrigin = origin;
    // First frame: record the baseline, never correct against it.
    if (previous == null || origin == previous) return;
    widget.tab.pan -= origin - previous;
    AppState.instance.notifyChange();
  }

  Offset get _effectivePan => widget.tab.pan + _panDelta;
  double get _scale => widget.tab.scale;

  void _onBackgroundPanUpdate(DragUpdateDetails d) {
    setState(() => _panDelta += d.delta);
  }

  void _onBackgroundPanEnd() {
    if (_panDelta == Offset.zero) return;
    widget.tab.pan += _panDelta;
    _panDelta = Offset.zero;
    AppState.instance.notifyChange();
  }

  void _onNodeDragStart(LinkedNode node) {
    setState(() {
      _dragNodeId = node.id;
      _dragDelta = Offset.zero;
      _topNodeId = node.id;
    });
  }

  void _bringToFront(LinkedNode node) {
    if (_topNodeId == node.id) return;
    setState(() => _topNodeId = node.id);
  }

  void _onNodeDragUpdate(DragUpdateDetails d) {
    // _NodeShell sits inside a FittedBox that hit-tests with the inverse
    // scale applied, so gesture deltas reported inside the shell are
    // already in canvas (unscaled) units — no further division needed.
    setState(() => _dragDelta += d.delta);
  }

  void _onNodeDragEnd() {
    final id = _dragNodeId;
    if (id == null) {
      setState(() {
        _dragDelta = Offset.zero;
      });
      return;
    }
    final node = widget.tab.nodes.cast<LinkedNode?>().firstWhere(
      (n) => n?.id == id,
      orElse: () => null,
    );
    if (node != null && _dragDelta != Offset.zero) {
      node.position += _dragDelta;
    }
    setState(() {
      _dragNodeId = null;
      _dragDelta = Offset.zero;
    });
    if (node != null) AppState.instance.notifyChange();
  }

  /// Mouse wheel + Ctrl/Cmd zooms the canvas around the pointer. Plain
  /// wheel passes through so trackpad scroll on a list node still works.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl =
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
    if (!ctrl) return;
    final factor = event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1;
    final newScale = (widget.tab.scale * factor).clamp(0.25, 3.0);
    if (newScale == widget.tab.scale) return;
    // Keep the point under the cursor stable. Canvas-space point under
    // the cursor before the zoom equals (screen - pan) / scale; after the
    // zoom we want the same canvas point under the same screen point, so
    // pan must move to: screen - canvasPoint * newScale.
    final box = context.findRenderObject() as RenderBox?;
    if (box != null) {
      final local = box.globalToLocal(event.position);
      final canvasPoint = (local - _effectivePan) / widget.tab.scale;
      widget.tab.pan = local - canvasPoint * newScale - _panDelta;
    }
    widget.tab.scale = newScale;
    AppState.instance.notifyChange();
  }

  /// Build only the LinkedRowNode positions. `_topNodeId` (if any) is
  /// rendered last so it stacks on top.
  List<Widget> _buildRowNodes(Offset pan) {
    final fks = widget.tab.foreignKeys;
    final rows = <LinkedRowNode>[
      for (final n in widget.tab.nodes)
        if (n is LinkedRowNode) n,
    ];
    final topIdx = _topNodeId == null
        ? -1
        : rows.indexWhere((n) => n.id == _topNodeId);
    if (topIdx >= 0) {
      final top = rows.removeAt(topIdx);
      rows.add(top);
    }
    return [
      for (final node in rows)
        () {
          // Auto-fit the width once FKs are loaded and the user hasn't
          // resized the card themselves. We only widen, never shrink —
          // so a manual resize sticks.
          if (widget.tab.fksLoaded && !_autoSizedOnce.contains(node.id)) {
            final fit = _autoWidthFor(node, fks);
            if (fit > node.width) node.width = fit;
            _autoSizedOnce.add(node.id);
          }
          final h = _nodeHeightFor(node, fks);
          final w = node.width;
          return Positioned(
            key: ValueKey(node.id),
            left:
                pan.dx +
                (node.position.dx +
                        (node.id == _dragNodeId ? _dragDelta.dx : 0)) *
                    _scale,
            top:
                pan.dy +
                (node.position.dy +
                        (node.id == _dragNodeId ? _dragDelta.dy : 0)) *
                    _scale,
            width: w * _scale,
            height: h * _scale,
            child: _ScaledNode(
              scale: _scale,
              width: w,
              height: h,
              child: _NodeShell(
                node: node,
                tab: widget.tab,
                isSelected: widget.tab.selectedNodeId == node.id,
                onDragStart: () => _onNodeDragStart(node),
                onDragUpdate: _onNodeDragUpdate,
                onDragEnd: _onNodeDragEnd,
                onTap: () {
                  _bringToFront(node);
                  widget.tab.selectedNodeId = node.id;
                  widget.tab.previewRow = null;
                  AppState.instance.notifyChange();
                },
                onMount: () => widget.onRowNodeMounted(node),
                onActivate: widget.onRowNodeActivate == null
                    ? null
                    : () => widget.onRowNodeActivate!(node),
                onSecondaryTapDown: (globalPos) =>
                    widget.onNodeContextMenu?.call(node, globalPos),
                onResizeUpdate: (deltaCanvas) {
                  setState(() {
                    node.width = (node.width + deltaCanvas).clamp(
                      _kMinNodeWidth,
                      1000.0,
                    );
                  });
                },
                onResizeEnd: () => AppState.instance.notifyChange(),
              ),
            ),
          );
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final rowCount = tab.nodes.whereType<LinkedRowNode>().length;
    if (rowCount == 0) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: _onBackgroundPanUpdate,
        onPanEnd: (_) => _onBackgroundPanEnd(),
        child: const EmptyState(
          icon: Icons.hub_outlined,
          iconSize: 56,
          message:
              'Pick a row from the left panel to drop it on the canvas. '
              'Its FK-linked rows expand automatically.',
        ),
      );
    }

    final pan = _effectivePan;

    // Background-pan is its own layer in the Stack BENEATH the nodes —
    // hit tests resolve top-down, so a drag that starts on a node body
    // never reaches the background pan handler (which would otherwise
    // steal text selection / cell edit gestures).
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: _onBackgroundPanUpdate,
                onPanEnd: (_) => _onBackgroundPanEnd(),
              ),
            ),
            IgnorePointer(
              child: CustomPaint(
                painter: _EdgePainter(
                  tab: tab,
                  pan: pan,
                  scale: _scale,
                  dragNodeId: _dragNodeId,
                  dragDelta: _dragDelta,
                  tickerValue: _tickerValue,
                ),
              ),
            ),
            // Only row nodes render as cards. LinkedListNode is kept for
            // bookkeeping but no longer drawn — the left side panel is the
            // searchable row picker now.
            ..._buildRowNodes(pan),
          ],
        ),
      ),
    );
  }
}

/// Scales the child to fill the laid-out (already-scaled) `Positioned`
/// slot. Internally renders the child at its natural unscaled size and
/// uses FittedBox to scale during paint — this lets the edge painter
/// keep using the unscaled column layout coordinates while the visible
/// card matches the Positioned dimensions exactly. Direct
/// `Transform.scale` doesn't work here because tight parent constraints
/// prevent the inner SizedBox from reaching its requested unscaled
/// size, which causes the scale to compound and the connector
/// endpoints to drift away from the card edges as you zoom.
class _ScaledNode extends StatelessWidget {
  final double scale;
  final double width;
  final double height;
  final Widget child;
  const _ScaledNode({
    required this.scale,
    required this.width,
    required this.height,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (scale == 1.0) {
      return SizedBox(width: width, height: height, child: child);
    }
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: height,
        child: child,
      ),
    );
  }
}
