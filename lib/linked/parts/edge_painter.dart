part of '../linked_view.dart';

// ---------------------------------------------------------------------------
// Edge painter — gradient stroke + two animated chevrons per edge,
// matching the SchemaCanvas's GradientEdgePainter style so the Schema
// viewer and Linked view feel like one product. Animation timing,
// alpha values, and bezier formula track admin_site's React Flow
// GradientEdge exactly.
//
// Endpoints pick the shortest-distance side pair (L/R/T/B) per edge so
// vertically-stacked cards get top↔bottom connectors instead of long
// loops around the rim.
// ---------------------------------------------------------------------------

const int _kChevronCount = 2;
const double _kChevronSize = 6.0;

enum _LinkedAnchorSide { left, right, top, bottom }

extension on _LinkedAnchorSide {
  Offset get direction => switch (this) {
    _LinkedAnchorSide.left => const Offset(-1, 0),
    _LinkedAnchorSide.right => const Offset(1, 0),
    _LinkedAnchorSide.top => const Offset(0, -1),
    _LinkedAnchorSide.bottom => const Offset(0, 1),
  };
}

class _EdgePainter extends CustomPainter {
  final LinkedTab tab;
  final Offset pan;
  final double scale;
  final String? dragNodeId;
  final Offset dragDelta;

  /// 0..1, repeats every chevron cycle. Drives chevron position along
  /// each path.
  final double tickerValue;

  const _EdgePainter({
    required this.tab,
    required this.pan,
    required this.scale,
    required this.dragNodeId,
    required this.dragDelta,
    required this.tickerValue,
  });

  Rect _rectOf(LinkedNode n) {
    final dx = n.position.dx + (n.id == dragNodeId ? dragDelta.dx : 0);
    final dy = n.position.dy + (n.id == dragNodeId ? dragDelta.dy : 0);
    final h = n is LinkedRowNode
        ? _nodeHeightFor(n, tab.foreignKeys)
        : _kHeaderHeight + _kRowHeight;
    return Rect.fromLTWH(
      pan.dx + dx * scale,
      pan.dy + dy * scale,
      n.width * scale,
      h * scale,
    );
  }

  /// Anchor point on [side] of [rect]. For LinkedRowNodes the L/R
  /// anchors land on the [columnName] row's y-centre when that column
  /// is exposed; T/B anchors and missing columns fall back to rim
  /// midpoints.
  Offset _anchorOn(
    LinkedNode node,
    Rect rect,
    _LinkedAnchorSide side,
    String? columnName,
  ) {
    switch (side) {
      case _LinkedAnchorSide.right:
        return Offset(
          rect.right,
          _rowY(node, rect, columnName) ?? rect.center.dy,
        );
      case _LinkedAnchorSide.left:
        return Offset(
          rect.left,
          _rowY(node, rect, columnName) ?? rect.center.dy,
        );
      case _LinkedAnchorSide.top:
        return Offset(rect.center.dx, rect.top);
      case _LinkedAnchorSide.bottom:
        return Offset(rect.center.dx, rect.bottom);
    }
  }

  double? _rowY(LinkedNode node, Rect rect, String? columnName) {
    if (node is! LinkedRowNode || columnName == null) return null;
    final yLocal = _columnAnchorYFor(node, tab.foreignKeys, columnName);
    if (yLocal == null) return null;
    return rect.top + yLocal * scale;
  }

  /// Shortest-distance side picker, with the "anchor must face the
  /// other card" filter so we don't end up with a curve that loops
  /// back through the body.
  ({
    _LinkedAnchorSide aSide,
    _LinkedAnchorSide bSide,
    Offset a,
    Offset b,
  })
  _pickBestPair({
    required LinkedNode src,
    required Rect srcRect,
    required LinkedNode tgt,
    required Rect tgtRect,
    required String? sourceField,
    required String? targetField,
  }) {
    _LinkedAnchorSide? bestASide;
    _LinkedAnchorSide? bestBSide;
    Offset bestA = srcRect.center;
    Offset bestB = tgtRect.center;
    double bestDist = double.infinity;

    for (final aSide in _LinkedAnchorSide.values) {
      final aPt = _anchorOn(src, srcRect, aSide, sourceField);
      final aDir = aSide.direction;
      for (final bSide in _LinkedAnchorSide.values) {
        final bPt = _anchorOn(tgt, tgtRect, bSide, targetField);
        final ab = bPt - aPt;
        final aForward = aDir.dx * ab.dx + aDir.dy * ab.dy;
        if (aForward < 0) continue;
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

    if (bestASide == null || bestBSide == null) {
      final sourceOnRight = srcRect.center.dx <= tgtRect.center.dx;
      bestASide = sourceOnRight
          ? _LinkedAnchorSide.right
          : _LinkedAnchorSide.left;
      bestBSide = sourceOnRight
          ? _LinkedAnchorSide.left
          : _LinkedAnchorSide.right;
      bestA = _anchorOn(src, srcRect, bestASide, sourceField);
      bestB = _anchorOn(tgt, tgtRect, bestBSide, targetField);
    }

    return (aSide: bestASide, bSide: bestBSide, a: bestA, b: bestB);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final n in tab.nodes) n.id: n};
    final selectedId = tab.selectedNodeId;
    final highlighted = <String>{};
    if (selectedId != null) {
      highlighted.add(selectedId);
      for (final e in tab.edges) {
        if (e.fromNodeId == selectedId) highlighted.add(e.toNodeId);
        if (e.toNodeId == selectedId) highlighted.add(e.fromNodeId);
      }
    }

    final geoms = <_LinkedEdgeGeom>[];
    for (final edge in tab.edges) {
      final from = byId[edge.fromNodeId];
      final to = byId[edge.toNodeId];
      if (from == null || to == null) continue;
      final fromRect = _rectOf(from);
      final toRect = _rectOf(to);
      final pick = _pickBestPair(
        src: from,
        srcRect: fromRect,
        tgt: to,
        tgtRect: toRect,
        sourceField: edge.fromColumn,
        targetField: edge.toColumn,
      );
      final fromColor = _colorForNode(from);
      final toColor = _colorForNode(to);
      final hasSel = selectedId != null;
      final isHighlighted =
          hasSel &&
          highlighted.contains(edge.fromNodeId) &&
          highlighted.contains(edge.toNodeId);
      final dimmed = hasSel && !isHighlighted;
      geoms.add(
        _LinkedEdgeGeom(
          start: pick.a,
          end: pick.b,
          startSide: pick.aSide,
          endSide: pick.bSide,
          fromColor: fromColor,
          toColor: toColor,
          highlighted: isHighlighted,
          dimmed: dimmed,
        ),
      );
    }
    for (final g in geoms) {
      _drawStroke(canvas, g);
    }
    for (final g in geoms) {
      _drawChevrons(canvas, g);
    }
  }

  void _drawStroke(Canvas canvas, _LinkedEdgeGeom g) {
    final path = _bezier(g.start, g.startSide, g.end, g.endSide);
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

  void _drawChevrons(Canvas canvas, _LinkedEdgeGeom g) {
    final path = _bezier(g.start, g.startSide, g.end, g.endSide);
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

  /// Cubic bezier matching admin_site's React Flow `getBezierPath`,
  /// generalised to all four sides. Control point at each end is
  /// pulled along that side's outward direction by an offset that
  /// depends on the signed projected distance along that axis:
  /// forward (target ahead of anchor): offset = 0.5 × distance
  /// backward (anchors face same way): offset = curvature × 25 × √(-distance)
  /// curvature = 0.35.
  Path _bezier(
    Offset a,
    _LinkedAnchorSide aSide,
    Offset b,
    _LinkedAnchorSide bSide,
  ) {
    const curvature = 0.35;
    final aDir = aSide.direction;
    final bDir = bSide.direction;
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
  bool shouldRepaint(covariant _EdgePainter old) => true;
}

class _LinkedEdgeGeom {
  final Offset start;
  final Offset end;
  final _LinkedAnchorSide startSide;
  final _LinkedAnchorSide endSide;
  final Color fromColor;
  final Color toColor;
  final bool highlighted;
  final bool dimmed;
  const _LinkedEdgeGeom({
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
