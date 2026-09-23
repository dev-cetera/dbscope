import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'schema_layout.dart';
import 'schema_model.dart';
import 'table_colors.dart';

/// Two chevrons per edge animating along the bezier path so direction
/// reads at a glance without marching-ants noise.
const int _kChevronCount = 2;
const double _kChevronSize = 6.0;

/// Which side of a card an edge endpoint sits on. The bezier control
/// point pulls along this side's outward direction, so the curve
/// approaches each card perpendicular to its rim instead of cutting
/// into the body.
enum _Side { left, right, top, bottom }

extension on _Side {
  /// Outward unit vector for this side. Control points are pulled
  /// `offset × direction` away from the anchor point so the curve
  /// always heads outward first.
  Offset get direction => switch (this) {
        _Side.left => const Offset(-1, 0),
        _Side.right => const Offset(1, 0),
        _Side.top => const Offset(0, -1),
        _Side.bottom => const Offset(0, 1),
      };
}

class _EdgeGeom {
  final SchemaEdgeData edge;
  final Offset start;
  final Offset end;
  final _Side startSide;
  final _Side endSide;
  final Color fromColor;
  final Color toColor;
  final bool highlighted;
  final bool dimmed;
  const _EdgeGeom({
    required this.edge,
    required this.start,
    required this.end,
    required this.startSide,
    required this.endSide,
    required this.fromColor,
    required this.toColor,
    required this.highlighted,
    required this.dimmed,
  });
}

class SchemaEdgePainter extends CustomPainter {
  final List<SchemaNodeData> nodes;
  final List<SchemaEdgeData> edges;
  final Offset pan;
  final double scale;

  /// 0..1, drives chevron position along each path. Hosts feed this
  /// from a [Ticker] so chevrons animate continuously without per-edge
  /// rebuild cost.
  final double tickerValue;

  /// Selected node id; controls which edges are highlighted / dimmed.
  final String? selectedId;

  /// Set of nodes that are visually highlighted (typically the
  /// selection + its 1-hop FK neighbours). Edges between any two
  /// nodes in this set render highlighted; everything else is dimmed
  /// when a selection exists.
  final Set<String> highlightedNodeIds;

  /// Currently-dragged node id (if any). Edges anchored to this node
  /// add [dragDelta] to its rendered position so connectors track the
  /// card live while it's being moved.
  final String? dragNodeId;
  final Offset dragDelta;

  SchemaEdgePainter({
    required this.nodes,
    required this.edges,
    required this.pan,
    required this.scale,
    required this.tickerValue,
    required this.selectedId,
    required this.highlightedNodeIds,
    this.dragNodeId,
    this.dragDelta = Offset.zero,
  });

  Rect _screenRect(SchemaNodeData n) {
    final r = rectForNode(n);
    final dx = n.id == dragNodeId ? dragDelta.dx : 0.0;
    final dy = n.id == dragNodeId ? dragDelta.dy : 0.0;
    return Rect.fromLTWH(
      pan.dx + (r.left + dx) * scale,
      pan.dy + (r.top + dy) * scale,
      r.width * scale,
      r.height * scale,
    );
  }

  /// Anchor point on [side] of [rect]. When the side is left/right
  /// AND [columnName] resolves to a visible row, anchor at the row's
  /// y-centre so the edge appears to leave the exact field row.
  /// Top/bottom anchors use the rect's centre x — column-row resolution
  /// only makes sense on the horizontal rim because rows are
  /// horizontal stripes inside the card.
  Offset _anchorOn(
    SchemaNodeData node,
    Rect rect,
    _Side side,
    String? columnName,
  ) {
    switch (side) {
      case _Side.right:
        return Offset(
          rect.right,
          _rowY(node, rect, columnName) ?? rect.center.dy,
        );
      case _Side.left:
        return Offset(
          rect.left,
          _rowY(node, rect, columnName) ?? rect.center.dy,
        );
      case _Side.top:
        return Offset(rect.center.dx, rect.top);
      case _Side.bottom:
        return Offset(rect.center.dx, rect.bottom);
    }
  }

  double? _rowY(SchemaNodeData node, Rect rect, String? columnName) {
    if (columnName == null) return null;
    final yLocal = columnLocalCentreY(node, columnName);
    if (yLocal == null) return null;
    return rect.top + yLocal * scale;
  }

  /// Pick the (source side, target side) pair that minimises the
  /// Euclidean distance between the resulting anchor points, but only
  /// among "sensible" pairs — those where each anchor's outward
  /// direction actually faces the other card. Without that filter,
  /// e.g. two side-by-side cards could pick (top, top) just because
  /// the corners are slightly closer than the rim midpoints, producing
  /// a bezier that loops back into the card body.
  ({_Side aSide, _Side bSide, Offset a, Offset b}) _pickBestPair({
    required SchemaNodeData src,
    required Rect srcRect,
    required SchemaNodeData tgt,
    required Rect tgtRect,
    required String? sourceField,
    required String? targetField,
  }) {
    _Side? bestASide;
    _Side? bestBSide;
    Offset bestA = srcRect.center;
    Offset bestB = tgtRect.center;
    double bestDist = double.infinity;

    for (final aSide in _Side.values) {
      final aPt = _anchorOn(src, srcRect, aSide, sourceField);
      final aDir = aSide.direction;
      for (final bSide in _Side.values) {
        final bPt = _anchorOn(tgt, tgtRect, bSide, targetField);
        final ab = bPt - aPt;

        // Source anchor must face toward the target (positive
        // projection onto its outward direction).
        final aForward = aDir.dx * ab.dx + aDir.dy * ab.dy;
        if (aForward < 0) continue;

        // Target anchor must face back toward the source.
        final bDir = bSide.direction;
        final bForward = bDir.dx * (-ab.dx) + bDir.dy * (-ab.dy);
        if (bForward < 0) continue;

        final dist = ab.distance;
        if (dist < bestDist) {
          bestDist = dist;
          bestASide = aSide;
          bestBSide = bSide;
          bestA = aPt;
          bestB = bPt;
        }
      }
    }

    // Cards overlap or are coincident — fall back to whichever
    // horizontal side faces the other so we never emit a degenerate
    // edge. This mirrors React Flow's right/left default handles.
    if (bestASide == null || bestBSide == null) {
      final sourceOnRight = srcRect.center.dx <= tgtRect.center.dx;
      bestASide = sourceOnRight ? _Side.right : _Side.left;
      bestBSide = sourceOnRight ? _Side.left : _Side.right;
      bestA = _anchorOn(src, srcRect, bestASide, sourceField);
      bestB = _anchorOn(tgt, tgtRect, bestBSide, targetField);
    }

    return (aSide: bestASide, bSide: bestBSide, a: bestA, b: bestB);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final nodeById = {for (final n in nodes) n.id: n};
    final geoms = <_EdgeGeom>[];
    final hasSel = selectedId != null;
    for (final e in edges) {
      final src = nodeById[e.sourceId];
      final tgt = nodeById[e.targetId];
      if (src == null || tgt == null) continue;
      final srcRect = _screenRect(src);
      final tgtRect = _screenRect(tgt);
      final pick = _pickBestPair(
        src: src,
        srcRect: srcRect,
        tgt: tgt,
        tgtRect: tgtRect,
        sourceField: e.sourceField,
        targetField: e.targetField,
      );
      final fromColor = colorForTable('${src.schema}.${src.tableName}');
      final toColor = colorForTable('${tgt.schema}.${tgt.tableName}');
      final highlighted = hasSel &&
          highlightedNodeIds.contains(e.sourceId) &&
          highlightedNodeIds.contains(e.targetId);
      final dimmed = hasSel && !highlighted;
      geoms.add(
        _EdgeGeom(
          edge: e,
          start: pick.a,
          end: pick.b,
          startSide: pick.aSide,
          endSide: pick.bSide,
          fromColor: fromColor,
          toColor: toColor,
          highlighted: highlighted,
          dimmed: dimmed,
        ),
      );
    }

    for (final g in geoms) {
      _drawEdge(canvas, g);
    }
    for (final g in geoms) {
      _drawChevrons(canvas, g);
    }
  }

  void _drawEdge(Canvas canvas, _EdgeGeom g) {
    final path = _bezierPath(g.start, g.startSide, g.end, g.endSide);
    final alpha = g.dimmed ? 0.18 : 1.0;
    final shader = LinearGradient(
      colors: [
        g.fromColor.withValues(alpha: alpha),
        g.toColor.withValues(alpha: alpha),
      ],
    ).createShader(Rect.fromPoints(g.start, g.end));
    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = (g.highlighted ? 2.6 : 1.8) * scale
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, paint);
  }

  void _drawChevrons(Canvas canvas, _EdgeGeom g) {
    final path = _bezierPath(g.start, g.startSide, g.end, g.endSide);
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final total = metrics.fold<double>(0, (a, b) => a + b.length);
    if (total < 1) return;
    final alpha = g.dimmed ? 0.19 : 0.95;
    for (var i = 0; i < _kChevronCount; i++) {
      final phase = (tickerValue + i / _kChevronCount) % 1.0;
      final at = phase * total;
      double remaining = at;
      Offset? pos;
      double tangentAngle = 0;
      for (final m in metrics) {
        if (remaining <= m.length) {
          final t = m.getTangentForOffset(remaining);
          if (t != null) {
            pos = t.position;
            tangentAngle = math.atan2(t.vector.dy, t.vector.dx);
          }
          break;
        }
        remaining -= m.length;
      }
      if (pos == null) continue;
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(tangentAngle);
      final paint = Paint()..color = g.toColor.withValues(alpha: alpha);
      final s = _kChevronSize * scale;
      final p = Path()
        ..moveTo(-s, -s * 0.7)
        ..lineTo(0, 0)
        ..lineTo(-s, s * 0.7)
        ..close();
      canvas.drawPath(p, paint);
      canvas.restore();
    }
  }

  /// Cubic bezier matching React Flow's `getBezierPath`, generalised
  /// to all four sides. The control point at each end is pulled along
  /// that side's outward direction by an offset that depends on the
  /// signed projected distance along that axis:
  /// forward (target ahead of anchor): offset = 0.5 × distance
  /// backward (anchors face same way): offset = curvature × 25 × √(-distance)
  /// curvature = 0.35, the same value admin_site passes to
  /// `getBezierPath`. For horizontal sides (left/right) the offset
  /// lives on x; for vertical sides (top/bottom) on y.
  Path _bezierPath(Offset a, _Side aSide, Offset b, _Side bSide) {
    const curvature = 0.35;
    final aDir = aSide.direction;
    final bDir = bSide.direction;
    // Signed distance: how far the target sits along the anchor's
    // outward direction. Positive = forward, negative = backward.
    final aDist = (b.dx - a.dx) * aDir.dx + (b.dy - a.dy) * aDir.dy;
    final bDist = (a.dx - b.dx) * bDir.dx + (a.dy - b.dy) * bDir.dy;
    double offsetFor(double dist) {
      if (dist >= 0) return 0.5 * dist;
      return curvature * 25 * math.sqrt(-dist);
    }

    final c1 = Offset(
      a.dx + aDir.dx * offsetFor(aDist),
      a.dy + aDir.dy * offsetFor(aDist),
    );
    final c2 = Offset(
      b.dx + bDir.dx * offsetFor(bDist),
      b.dy + bDir.dy * offsetFor(bDist),
    );
    return Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, b.dx, b.dy);
  }

  @override
  bool shouldRepaint(covariant SchemaEdgePainter old) => true;
}
