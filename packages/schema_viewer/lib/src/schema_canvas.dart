import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'gradient_edge_painter.dart';
import 'schema_card.dart';
import 'schema_layout.dart';
import 'schema_model.dart';

/// Imperative handle on a live [SchemaCanvas]. Hosts can hand it to
/// header buttons (zoom in / zoom out / fit-to-view) without having
/// to compute focal-point pan math themselves. Attach via
/// [SchemaCanvas.controller].
class SchemaCanvasController {
  _SchemaCanvasState? _state;

  void _attach(_SchemaCanvasState state) {
    _state = state;
  }

  void _detach(_SchemaCanvasState state) {
    if (identical(_state, state)) _state = null;
  }

  /// Multiply the current scale by [factor] (1.5 = zoom in 50 %),
  /// keeping the viewport centre stable. No-op if no canvas is
  /// attached or the new scale is out of range.
  void zoomBy(double factor) => _state?.zoomBy(factor);

  /// Re-run the auto-fit pass against the current node positions.
  void fitView() => _state?.fitView();
}

/// Callbacks bundled and passed to a custom [cardBuilder] so the host
/// can wrap the default [SchemaCard] in extra widgets while keeping
/// drag / select / resize behaviour intact.
class SchemaCanvasCardCallbacks {
  final VoidCallback? onTap;
  final VoidCallback? onHeaderPanStart;
  final void Function(DragUpdateDetails details)? onHeaderPanUpdate;
  final VoidCallback? onHeaderPanEnd;
  final void Function(Offset globalPosition)? onSecondaryTapDown;
  final VoidCallback? onToggleCompact;
  final VoidCallback? onActivate;
  const SchemaCanvasCardCallbacks({
    this.onTap,
    this.onHeaderPanStart,
    this.onHeaderPanUpdate,
    this.onHeaderPanEnd,
    this.onSecondaryTapDown,
    this.onToggleCompact,
    this.onActivate,
  });
}

/// Pan-zoom-drag canvas that lays out [SchemaCard]s plus gradient
/// edges with animated chevrons. Selection is single-card; tapping the
/// background clears it. The host owns selection + per-node state and
/// supplies callbacks for activation, resize, compact-toggle, etc.
///
/// Used by:
/// * a Schema-viewer tab to render every table in a connection
/// * a Linked-view canvas to render the rows that participate in a
/// user-driven FK chain
///
/// Both consumers share this widget; only the "what to do when a card
/// is activated" wiring differs.
class SchemaCanvas extends StatefulWidget {
  final List<SchemaNodeData> nodes;
  final List<SchemaEdgeData> edges;

  /// Current pan/zoom — the canvas mutates them via [onPanChanged] /
  /// [onScaleChanged] on commit. Held externally so the host can
  /// persist them.
  final Offset pan;
  final double scale;
  final ValueChanged<Offset>? onPanChanged;
  final ValueChanged<double>? onScaleChanged;

  /// Selection state. Tapping the background clears the selection.
  final String? selectedId;
  final ValueChanged<String?> onSelectedChanged;

  /// Called after the user releases a drag, with the moved node's id.
  /// The host can persist the new position.
  final void Function(String nodeId)? onResizeEnd;

  /// Called when the user toggles compact mode from the header button.
  final void Function(String nodeId, bool willBeCompact)? onCompactToggled;

  /// Custom card renderer. Defaults to a plain [SchemaCard]. Hosts
  /// that need a wrapper (e.g. to overlay a resize handle, or to embed
  /// schema state) pass their own builder; the callbacks remain wired
  /// through [SchemaCanvasCardCallbacks].
  final Widget Function(
    BuildContext context,
    SchemaNodeData node,
    bool isSelected,
    bool isHighlighted,
    bool hasSelection,
    SchemaCanvasCardCallbacks cb,
  )? cardBuilder;

  /// Called when the user clicks the card's "open" header button.
  /// Hosts wire this to their drill-in action (open table view, open
  /// inspector, focus row, etc.). When null, the open button is
  /// hidden on every card.
  final void Function(String nodeId)? onCardActivated;

  /// Tooltip for the activate button. Defaults to "Open".
  final String cardActivateTooltip;

  /// Icon for the activate button. Defaults to [Icons.open_in_new].
  final IconData cardActivateIcon;

  /// Right-click handler on a card.
  final void Function(String nodeId, Offset globalPosition)? onCardSecondaryTap;

  /// Show a subtle dot grid behind the cards (the same effect React
  /// Flow's `<Background />` ships). Off by default — hosts may turn
  /// it on per theme. Spacing is 20 canvas-units.
  final bool showBackgroundGrid;

  /// When non-null, the canvas computes a fit-view zoom/pan on the
  /// first layout pass that contains node positions. Hosts pass the
  /// current viewport size via a LayoutBuilder; only the first call
  /// per [SchemaCanvas] instance fires.
  final bool autoFitOnFirstLayout;

  /// Optional controller for imperative zoom / fit-view from outside
  /// the canvas (header buttons, keyboard shortcuts, etc).
  final SchemaCanvasController? controller;

  const SchemaCanvas({
    super.key,
    required this.nodes,
    required this.edges,
    required this.pan,
    required this.scale,
    required this.onPanChanged,
    required this.onScaleChanged,
    required this.selectedId,
    required this.onSelectedChanged,
    this.onResizeEnd,
    this.onCompactToggled,
    this.cardBuilder,
    this.onCardActivated,
    this.cardActivateTooltip = 'Open',
    this.cardActivateIcon = Icons.open_in_new,
    this.onCardSecondaryTap,
    this.showBackgroundGrid = true,
    this.autoFitOnFirstLayout = true,
    this.controller,
  });

  @override
  State<SchemaCanvas> createState() => _SchemaCanvasState();
}

class _SchemaCanvasState extends State<SchemaCanvas>
    with SingleTickerProviderStateMixin {
  Offset _panDelta = Offset.zero;
  String? _dragNodeId;
  Offset _dragDelta = Offset.zero;

  /// Most-recently-interacted node renders last so its shadow / outline
  /// sit on top.
  String? _topNodeId;

  late final Ticker _ticker;
  double _tickerValue = 0;
  Duration _lastTick = Duration.zero;
  // Slower than admin_site's React Flow 3.5s cycle — the user found
  // the faster speed distracting on a packed schema.
  static const Duration _kChevronCycle = Duration(milliseconds: 6000);

  // Trackpad pinch state. We track baseline scale on PointerPanZoomStart
  // and apply incremental factor on each update so the gesture feels
  // continuous instead of compounding.
  double _pinchBaseScale = 1.0;
  Offset _pinchPan = Offset.zero;
  Offset _pinchFocalLocal = Offset.zero;

  /// Has the host's onPanChanged + onScaleChanged seen a fit-view
  /// initialisation? We only fire it once per canvas instance.
  bool _autoFitDone = false;

  /// Where this canvas's top-left sat inside the window on the previous
  /// frame. See [_anchorViewport].
  Offset? _lastViewportOrigin;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant SchemaCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _ticker.dispose();
    super.dispose();
  }

  /// Reset the fit-view latch so the next build re-fits the diagram
  /// to the current viewport, then nudge a rebuild.
  void fitView() {
    _autoFitDone = false;
    if (mounted) setState(() {});
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

  /// Keep the diagram pinned to the screen when the viewport's own
  /// origin moves.
  ///
  /// [pan] is canvas-local, so a card sits at `pan + position * scale`
  /// measured from this widget's top-left. When a pane to the LEFT of
  /// the canvas opens or closes, that top-left slides sideways and the
  /// whole diagram slides with it. Shifting [pan] by the inverse holds
  /// every card at the same screen position instead.
  ///
  /// Only the canvas's offset INSIDE the window is consulted, which is
  /// what makes this precise: a pane on the right leaves it untouched
  /// (and needs no correction), and moving the OS window doesn't change
  /// it either, since Flutter's global coordinates are view-relative.
  ///
  /// Driven from the chevron ticker, which runs every frame for the
  /// life of the canvas — so this tracks a pane being *dragged* as
  /// smoothly as one being toggled, without depending on whether a
  /// rebuild or a re-layout happened to fire.
  void _anchorViewport() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final previous = _lastViewportOrigin;
    _lastViewportOrigin = origin;
    // First frame: record the baseline, never correct against it.
    if (previous == null || origin == previous) return;
    widget.onPanChanged?.call(widget.pan - (origin - previous));
  }

  Offset get _effectivePan => widget.pan + _panDelta;

  void _onBackgroundPanUpdate(DragUpdateDetails d) {
    setState(() => _panDelta += d.delta);
  }

  void _onBackgroundPanEnd() {
    if (_panDelta == Offset.zero) return;
    final committed = widget.pan + _panDelta;
    _panDelta = Offset.zero;
    widget.onPanChanged?.call(committed);
  }

  void _onBackgroundTap() {
    if (widget.selectedId != null) widget.onSelectedChanged(null);
  }

  void _onNodeDragStart(SchemaNodeData node) {
    setState(() {
      _dragNodeId = node.id;
      _dragDelta = Offset.zero;
      _topNodeId = node.id;
    });
  }

  /// Push every other node out of the way of [pivotId] using its
  /// CURRENT position + size. Called after a node's height changes
  /// (compact-toggle expand/collapse) so neighbours can never end up
  /// underneath the grown card.
  void _cascadeFromSizeChange(String pivotId) {
    final positions = <String, Offset>{
      for (final n in widget.nodes) n.id: n.position,
    };
    cascadeSeparate(
      movedIds: {pivotId},
      positions: positions,
      dimsFor: (otherId) {
        for (final n in widget.nodes) {
          if (n.id == otherId) {
            return (w: effectiveNodeWidth(n), h: renderedNodeHeight(n));
          }
        }
        return null;
      },
      allIds: positions.keys,
    );
    for (final n in widget.nodes) {
      if (n.id == pivotId) continue;
      final p = positions[n.id];
      if (p != null) n.position = p;
    }
  }

  /// Cascade-separate neighbours against the dragged node's virtual
  /// position (canvas-space `node.position + _dragDelta`). Mutates
  /// non-dragged nodes' `.position` in place so the host's host has
  /// the live layout. Mirrors admin_site/useDiagramPage's runCascade
  /// firing on each drag tick (not only on drag-end).
  void _cascadeNeighbours() {
    final id = _dragNodeId;
    if (id == null) return;
    final positions = <String, Offset>{};
    SchemaNodeData? dragged;
    for (final n in widget.nodes) {
      if (n.id == id) {
        dragged = n;
        positions[n.id] = n.position + _dragDelta;
      } else {
        positions[n.id] = n.position;
      }
    }
    if (dragged == null) return;
    cascadeSeparate(
      movedIds: {id},
      positions: positions,
      dimsFor: (otherId) {
        for (final n in widget.nodes) {
          if (n.id == otherId) {
            return (
              w: effectiveNodeWidth(n),
              h: renderedNodeHeight(n),
            );
          }
        }
        return null;
      },
      allIds: positions.keys,
    );
    for (final n in widget.nodes) {
      if (n.id == id) continue;
      final p = positions[n.id];
      if (p != null) n.position = p;
    }
  }

  void _onNodeDragUpdate(DragUpdateDetails d) {
    setState(() {
      _dragDelta += d.delta;
      _cascadeNeighbours();
    });
  }

  void _onNodeDragEnd() {
    final id = _dragNodeId;
    if (id == null) {
      setState(() => _dragDelta = Offset.zero);
      return;
    }
    SchemaNodeData? node;
    for (final n in widget.nodes) {
      if (n.id == id) {
        node = n;
        break;
      }
    }
    if (node != null && _dragDelta != Offset.zero) {
      node.position += _dragDelta;
      // Final cascade pass after committing the dragged-node position,
      // so the resting layout is the one the live drag already painted.
      _cascadeNeighbours();
    }
    setState(() {
      _dragNodeId = null;
      _dragDelta = Offset.zero;
    });
    if (node != null) widget.onResizeEnd?.call(id);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Plain wheel — discrete zoom step around the cursor.
    final factor = event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1;
    _applyZoomAt(event.localPosition, factor);
  }

  /// Trackpad pan / pinch start. macOS sends `PointerPanZoom*` events
  /// for two-finger gestures (NOT `PointerScrollEvent`), so the
  /// pointer-signal handler alone misses them. Without these handlers
  /// laptop users can't pan or pinch the canvas at all.
  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    _pinchBaseScale = widget.scale;
    _pinchPan = widget.pan + _panDelta;
    _pinchFocalLocal = event.localPosition;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    // Each update event carries cumulative pan + scale since the
    // gesture started. Recompute from baseline rather than integrating
    // deltas so a slow pinch + pan combo stays stable.
    final newScale = (_pinchBaseScale * event.scale).clamp(0.05, 2.0);
    final canvasPoint = (_pinchFocalLocal - _pinchPan) / _pinchBaseScale;
    // Pan = focal-preservation under the scale change + the user's
    // two-finger translation.
    final newPan = _pinchFocalLocal - canvasPoint * newScale + event.pan;
    _panDelta = Offset.zero;
    if (newScale != widget.scale) {
      widget.onScaleChanged?.call(newScale);
    }
    widget.onPanChanged?.call(newPan);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    if (_panDelta != Offset.zero) {
      final committed = widget.pan + _panDelta;
      _panDelta = Offset.zero;
      widget.onPanChanged?.call(committed);
    }
  }

  void _applyZoomAt(Offset localFocus, double factor) {
    final newScale = (widget.scale * factor).clamp(0.05, 2.0);
    if (newScale == widget.scale) return;
    final canvasPoint = (localFocus - _effectivePan) / widget.scale;
    final newPan = localFocus - canvasPoint * newScale - _panDelta;
    widget.onPanChanged?.call(newPan);
    widget.onScaleChanged?.call(newScale);
  }

  /// Public hook the host can call to zoom around the viewport
  /// centre — used by the Schema tab's +/- buttons.
  void zoomBy(double factor) {
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size.zero;
    _applyZoomAt(
      Offset(size.width / 2, size.height / 2),
      factor,
    );
  }

  /// Highlighted set = selection + 1-hop FK neighbours. Mirrors the
  /// admin_site `connected.nodes` semantics.
  Set<String> _computeHighlighted() {
    final id = widget.selectedId;
    if (id == null) return const {};
    final out = <String>{id};
    for (final e in widget.edges) {
      if (e.sourceId == id) out.add(e.targetId);
      if (e.targetId == id) out.add(e.sourceId);
    }
    return out;
  }

  Widget _buildCard(
    BuildContext context,
    SchemaNodeData node,
    bool isSelected,
    bool isHighlighted,
    bool hasSelection,
    SchemaCanvasCardCallbacks cb,
  ) {
    if (widget.cardBuilder != null) {
      return widget.cardBuilder!(
        context,
        node,
        isSelected,
        isHighlighted,
        hasSelection,
        cb,
      );
    }
    return SchemaCard(
      node: node,
      isSelected: isSelected,
      isHighlighted: isHighlighted,
      hasSelection: hasSelection,
      onTap: cb.onTap,
      onHeaderPanStart: cb.onHeaderPanStart,
      onHeaderPanUpdate: cb.onHeaderPanUpdate,
      onHeaderPanEnd: cb.onHeaderPanEnd,
      onSecondaryTapDown: cb.onSecondaryTapDown,
      onToggleCompact: cb.onToggleCompact,
      onActivate: cb.onActivate,
      activateTooltip: widget.cardActivateTooltip,
      activateIcon: widget.cardActivateIcon,
    );
  }

  /// Compute the pan/scale that fits all nodes into [viewport] with a
  /// padding margin (matching React Flow's fitView padding: 0.15).
  /// Called once per canvas instance after the first paint when
  /// [SchemaCanvas.autoFitOnFirstLayout] is true.
  void _maybeAutoFit(Size viewport) {
    if (_autoFitDone) return;
    if (!widget.autoFitOnFirstLayout) return;
    if (widget.nodes.isEmpty) return;
    if (viewport.width <= 0 || viewport.height <= 0) return;
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    for (final n in widget.nodes) {
      final r = rectForNode(n);
      if (r.left < minX) minX = r.left;
      if (r.top < minY) minY = r.top;
      if (r.right > maxX) maxX = r.right;
      if (r.bottom > maxY) maxY = r.bottom;
    }
    final contentW = maxX - minX;
    final contentH = maxY - minY;
    if (contentW <= 0 || contentH <= 0) return;
    const padding = 0.15;
    final usableW = viewport.width * (1 - padding * 2);
    final usableH = viewport.height * (1 - padding * 2);
    var fitScale = (usableW / contentW)
        .clamp(0.05, 1.0); // never zoom in past 1.0 — admin_site doesn't.
    final scaleY = (usableH / contentH).clamp(0.05, 1.0);
    if (scaleY < fitScale) fitScale = scaleY;
    final centreCanvasX = minX + contentW / 2;
    final centreCanvasY = minY + contentH / 2;
    final centreViewportX = viewport.width / 2;
    final centreViewportY = viewport.height / 2;
    final fitPan = Offset(
      centreViewportX - centreCanvasX * fitScale,
      centreViewportY - centreCanvasY * fitScale,
    );
    _autoFitDone = true;
    // Defer to after the current frame so listeners don't fire during
    // build (Flutter throws on setState in build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onScaleChanged?.call(fitScale);
      widget.onPanChanged?.call(fitPan);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maybeAutoFit(constraints.biggest);
        return _buildCanvasContent(context);
      },
    );
  }

  Widget _buildCanvasContent(BuildContext context) {
    final pan = _effectivePan;
    final scale = widget.scale;
    final highlighted = _computeHighlighted();
    final hasSel = widget.selectedId != null;

    final ordered = <SchemaNodeData>[...widget.nodes];
    if (_topNodeId != null) {
      final idx = ordered.indexWhere((n) => n.id == _topNodeId);
      if (idx >= 0) {
        final top = ordered.removeAt(idx);
        ordered.add(top);
      }
    }

    return Listener(
      onPointerSignal: _onPointerSignal,
      onPointerPanZoomStart: _onPanZoomStart,
      onPointerPanZoomUpdate: _onPanZoomUpdate,
      onPointerPanZoomEnd: _onPanZoomEnd,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.showBackgroundGrid)
              IgnorePointer(
                child: CustomPaint(
                  painter: _DotGridPainter(
                    pan: pan,
                    scale: scale,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.15),
                  ),
                ),
              ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: _onBackgroundPanUpdate,
                onPanEnd: (_) => _onBackgroundPanEnd(),
                onTap: _onBackgroundTap,
              ),
            ),
            IgnorePointer(
              child: CustomPaint(
                painter: SchemaEdgePainter(
                  nodes: widget.nodes,
                  edges: widget.edges,
                  pan: pan,
                  scale: scale,
                  tickerValue: _tickerValue,
                  selectedId: widget.selectedId,
                  highlightedNodeIds: highlighted,
                  // Pass live drag info so edges follow the moving
                  // card without waiting for drag-end.
                  dragNodeId: _dragNodeId,
                  dragDelta: _dragDelta,
                ),
              ),
            ),
            for (final node in ordered) ...[
              () {
                final isSelected = widget.selectedId == node.id;
                final isHighlighted = highlighted.contains(node.id);
                final w = effectiveNodeWidth(node);
                final h = renderedNodeHeight(node);
                final left = pan.dx +
                    (node.position.dx +
                            (node.id == _dragNodeId ? _dragDelta.dx : 0)) *
                        scale;
                final top = pan.dy +
                    (node.position.dy +
                            (node.id == _dragNodeId ? _dragDelta.dy : 0)) *
                        scale;
                final cb = SchemaCanvasCardCallbacks(
                  onTap: () {
                    setState(() => _topNodeId = node.id);
                    widget.onSelectedChanged(node.id);
                  },
                  onHeaderPanStart: () => _onNodeDragStart(node),
                  onHeaderPanUpdate: _onNodeDragUpdate,
                  onHeaderPanEnd: _onNodeDragEnd,
                  onSecondaryTapDown: widget.onCardSecondaryTap == null
                      ? null
                      : (gp) => widget.onCardSecondaryTap!(node.id, gp),
                  onToggleCompact: widget.onCompactToggled == null
                      ? null
                      : () {
                          final willBe = !node.compact;
                          node.compact = willBe;
                          // Card grew or shrank — cascade-separate so
                          // neighbours get pushed out of the way and
                          // can never sit on top of each other.
                          _cascadeFromSizeChange(node.id);
                          widget.onCompactToggled!(node.id, willBe);
                          setState(() {});
                        },
                  onActivate: widget.onCardActivated == null
                      ? null
                      : () => widget.onCardActivated!(node.id),
                );
                return Positioned(
                  key: ValueKey('node-${node.id}'),
                  left: left,
                  top: top,
                  width: w * scale,
                  height: h * scale,
                  child: _ScaledCard(
                    scale: scale,
                    width: w,
                    height: h,
                    child: _buildCard(
                      context,
                      node,
                      isSelected,
                      isHighlighted,
                      hasSel,
                      cb,
                    ),
                  ),
                );
              }(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Dot grid backdrop matching React Flow's `<Background variant="dots" />`.
/// Spacing is 20 canvas units; dots scale and translate with the
/// canvas pan/zoom so they look stationary relative to the diagram.
class _DotGridPainter extends CustomPainter {
  final Offset pan;
  final double scale;
  final Color color;
  const _DotGridPainter({
    required this.pan,
    required this.scale,
    required this.color,
  });

  static const double _kGridSpacing = 20.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final spacing = _kGridSpacing * scale;
    if (spacing < 4) return; // too dense to be readable at this zoom
    final paint = Paint()..color = color;
    // Align the grid so a dot lies at pan + (0,0) in screen space.
    final startX = pan.dx % spacing;
    final startY = pan.dy % spacing;
    for (double y = startY; y < size.height; y += spacing) {
      for (double x = startX; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 0.8 * scale.clamp(0.5, 2.0), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter old) {
    return old.pan != pan || old.scale != scale || old.color != color;
  }
}

/// Scales the child to fill the laid-out (already-scaled) Positioned
/// slot. The card always renders at natural pixel size and FittedBox
/// scales during paint — that way hit-tests and gesture deltas stay in
/// canvas (unscaled) space.
class _ScaledCard extends StatelessWidget {
  final double scale;
  final double width;
  final double height;
  final Widget child;
  const _ScaledCard({
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
      child: SizedBox(width: width, height: height, child: child),
    );
  }
}
