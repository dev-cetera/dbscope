/// @docImport 'package:flutter/scheduler.dart';
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'schema_layout.dart';
import 'schema_model.dart';
import 'table_colors.dart';

/// Two chevrons per edge animating along the bezier path so direction
/// reads at a glance without marching-ants noise.
const _kChevronCount = 2;
const _kChevronSize = 6.0;

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
        _Side.left => const Offset(-1.0, 0.0),
        _Side.right => const Offset(1.0, 0.0),
        _Side.top => const Offset(0.0, -1.0),
        _Side.bottom => const Offset(0.0, 1.0),
      };
}

class _EdgeGeom {
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
  final SchemaEdgeData edge;
  final Offset start;
  final Offset end;
  final _Side startSide;
  final _Side endSide;
  final Color fromColor;
  final Color toColor;
  final bool highlighted;
  final bool dimmed;
}

class SchemaEdgePainter extends CustomPainter {
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

  Rect _screenRect(SchemaNodeData node) {
    final rect = rectForNode(node);
    final dx = node.id == dragNodeId ? dragDelta.dx : 0.0;
    final dy = node.id == dragNodeId ? dragDelta.dy : 0.0;
    return Rect.fromLTWH(
      pan.dx + (rect.left + dx) * scale,
      pan.dy + (rect.top + dy) * scale,
      rect.width * scale,
      rect.height * scale,
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
  ({_Side aSide, _Side bSide, Offset aAnchor, Offset bAnchor}) _pickBestPair({
    required SchemaNodeData source,
    required Rect sourceRect,
    required SchemaNodeData target,
    required Rect targetRect,
    required String? sourceField,
    required String? targetField,
  }) {
    _Side? bestASide;
    _Side? bestBSide;
    var bestA = sourceRect.center;
    var bestB = targetRect.center;
    var bestDist = double.infinity;

    for (final aSide in _Side.values) {
      final aPoint = _anchorOn(source, sourceRect, aSide, sourceField);
      final aDirection = aSide.direction;
      for (final bSide in _Side.values) {
        final bPoint = _anchorOn(target, targetRect, bSide, targetField);
        final ab = bPoint - aPoint;

        // Source anchor must face toward the target (positive
        // projection onto its outward direction).
        final aForward = aDirection.dx * ab.dx + aDirection.dy * ab.dy;
        if (aForward < 0) continue;

        // Target anchor must face back toward the source.
        final bDirection = bSide.direction;
        final bForward = bDirection.dx * (-ab.dx) + bDirection.dy * (-ab.dy);
        if (bForward < 0) continue;

        final dist = ab.distance;
        if (dist < bestDist) {
          bestDist = dist;
          bestASide = aSide;
          bestBSide = bSide;
          bestA = aPoint;
          bestB = bPoint;
        }
      }
    }

    // Cards overlap or are coincident — fall back to whichever
    // horizontal side faces the other so we never emit a degenerate
    // edge. This mirrors React Flow's right/left default handles.
    if (bestASide == null || bestBSide == null) {
      final sourceOnRight = sourceRect.center.dx <= targetRect.center.dx;
      bestASide = sourceOnRight ? _Side.right : _Side.left;
      bestBSide = sourceOnRight ? _Side.left : _Side.right;
      bestA = _anchorOn(source, sourceRect, bestASide, sourceField);
      bestB = _anchorOn(target, targetRect, bestBSide, targetField);
    }

    return (
      aSide: bestASide,
      bSide: bestBSide,
      aAnchor: bestA,
      bAnchor: bestB,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final nodeById = {for (final node in nodes) node.id: node};
    final geoms = <_EdgeGeom>[];
    final hasSel = selectedId != null;
    for (final e in edges) {
      final source = nodeById[e.sourceId];
      final target = nodeById[e.targetId];
      if (source == null || target == null) continue;
      final sourceRect = _screenRect(source);
      final targetRect = _screenRect(target);
      final pick = _pickBestPair(
        source: source,
        sourceRect: sourceRect,
        target: target,
        targetRect: targetRect,
        sourceField: e.sourceField,
        targetField: e.targetField,
      );
      final fromColor = colorForTable('${source.schema}.${source.tableName}');
      final toColor = colorForTable('${target.schema}.${target.tableName}');
      final highlighted = hasSel &&
          highlightedNodeIds.contains(e.sourceId) &&
          highlightedNodeIds.contains(e.targetId);
      final dimmed = hasSel && !highlighted;
      geoms.add(
        _EdgeGeom(
          edge: e,
          start: pick.aAnchor,
          end: pick.bAnchor,
          startSide: pick.aSide,
          endSide: pick.bSide,
          fromColor: fromColor,
          toColor: toColor,
          highlighted: highlighted,
          dimmed: dimmed,
        ),
      );
    }

    for (final geometry in geoms) {
      _drawEdge(canvas, geometry);
    }
    for (final geometry in geoms) {
      _drawChevrons(canvas, geometry);
    }
  }

  void _drawEdge(Canvas canvas, _EdgeGeom geometry) {
    final path = _bezierPath(
      geometry.start,
      geometry.startSide,
      geometry.end,
      geometry.endSide,
    );
    final alpha = geometry.dimmed ? 0.18 : 1.0;
    final shader = LinearGradient(
      colors: [
        geometry.fromColor.withValues(alpha: alpha),
        geometry.toColor.withValues(alpha: alpha),
      ],
    ).createShader(Rect.fromPoints(geometry.start, geometry.end));
    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = (geometry.highlighted ? 2.6 : 1.8) * scale
      ..strokeCap = StrokeCap.round;
    if (!geometry.edge.dashed) {
      canvas.drawPath(path, paint);
      return;
    }
    // Dashed: walk the path and draw alternating segments.
    final dash = 6.0 * scale;
    final gap = 5.0 * scale;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  void _drawChevrons(Canvas canvas, _EdgeGeom geometry) {
    final path = _bezierPath(
      geometry.start,
      geometry.startSide,
      geometry.end,
      geometry.endSide,
    );
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final total = metrics.fold<double>(0, (a, b) => a + b.length);
    if (total < 1) return;
    final alpha = geometry.dimmed ? 0.19 : 0.95;
    for (var i = 0; i < _kChevronCount; i++) {
      final phase = (tickerValue + i / _kChevronCount) % 1.0;
      final at = phase * total;
      var remaining = at;
      Offset? position;
      double tangentAngle = 0;
      for (final metric in metrics) {
        if (remaining <= metric.length) {
          final tangent = metric.getTangentForOffset(remaining);
          if (tangent != null) {
            position = tangent.position;
            tangentAngle = math.atan2(tangent.vector.dy, tangent.vector.dx);
          }
          break;
        }
        remaining -= metric.length;
      }
      if (position == null) continue;
      canvas.save();
      canvas.translate(position.dx, position.dy);
      canvas.rotate(tangentAngle);
      final paint = Paint()..color = geometry.toColor.withValues(alpha: alpha);
      final chevronSize = _kChevronSize * scale;
      final chevronPath = Path()
        ..moveTo(-chevronSize, -chevronSize * 0.7)
        ..lineTo(0, 0)
        ..lineTo(-chevronSize, chevronSize * 0.7)
        ..close();
      canvas.drawPath(chevronPath, paint);
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
  Path _bezierPath(Offset aPoint, _Side aSide, Offset bPoint, _Side bSide) {
    const curvature = 0.35;
    final aDirection = aSide.direction;
    final bDirection = bSide.direction;
    // Signed distance: how far the target sits along the anchor's
    // outward direction. Positive = forward, negative = backward.
    final aDist = (bPoint.dx - aPoint.dx) * aDirection.dx +
        (bPoint.dy - aPoint.dy) * aDirection.dy;
    final bDist = (aPoint.dx - bPoint.dx) * bDirection.dx +
        (aPoint.dy - bPoint.dy) * bDirection.dy;
    double offsetFor(double dist) {
      if (dist >= 0) return 0.5 * dist;
      return curvature * 25 * math.sqrt(-dist);
    }

    final c1 = Offset(
      aPoint.dx + aDirection.dx * offsetFor(aDist),
      aPoint.dy + aDirection.dy * offsetFor(aDist),
    );
    final c2 = Offset(
      bPoint.dx + bDirection.dx * offsetFor(bDist),
      bPoint.dy + bDirection.dy * offsetFor(bDist),
    );
    return Path()
      ..moveTo(aPoint.dx, aPoint.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, bPoint.dx, bPoint.dy);
  }

  @override
  bool shouldRepaint(covariant SchemaEdgePainter old) => true;
}
