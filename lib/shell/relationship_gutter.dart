import 'package:flutter/material.dart';
import 'package:schema_viewer/schema_viewer.dart';

import '../catalog/schema_catalog.dart';

// Palette + colorForTable / colorIndexForTable / buildTableColorMap live
// in package:schema_viewer/schema_viewer.dart so the Schema viewer, the
// Linked view, and the sidebar's relationship gutter share one
// colour-per-table source of truth. Re-export here so existing
// `import '../shell/relationship_gutter.dart'` call sites keep working.
export 'package:schema_viewer/schema_viewer.dart'
    show
        buildTableColorMap,
        colorForTable,
        colorIndexForTable,
        kRelationshipPalette;

const double kGutterWidth = 32;
const double kGutterRowHeight = 24;

/// Returns one edge per unordered table pair. A FK from A->B and another
/// from B->A collapse to a single line; multiple FKs between the same pair
/// in the same direction also collapse. Self-FKs are skipped (they have no
/// gutter representation). Ordering is stable so the lane assignment in the
/// painter is deterministic across rebuilds.
List<ForeignKey> _stableSorted(List<ForeignKey> edges) {
  final sorted = [...edges];
  sorted.sort((a, b) {
    final c1 = a.fromKey.compareTo(b.fromKey);
    if (c1 != 0) return c1;
    final c2 = a.toKey.compareTo(b.toKey);
    if (c2 != 0) return c2;
    return a.fromColumn.compareTo(b.fromColumn);
  });
  final seen = <String>{};
  final out = <ForeignKey>[];
  for (final fk in sorted) {
    if (fk.fromKey == fk.toKey) continue;
    final lo = fk.fromKey.compareTo(fk.toKey) <= 0 ? fk.fromKey : fk.toKey;
    final hi = fk.fromKey.compareTo(fk.toKey) <= 0 ? fk.toKey : fk.fromKey;
    if (seen.add('$lo|$hi')) out.add(fk);
  }
  return out;
}

/// Tables on the other end of an FK from [selectedKey]. The sidebar uses this
/// set to brighten related rows; each row already knows its own colour via
/// [colorForTable], so we only need the membership.
Set<String> relatedTables(List<ForeignKey> edges, String? selectedKey) {
  if (selectedKey == null) return const {};
  final out = <String>{};
  for (final fk in edges) {
    if (fk.fromKey == fk.toKey) continue;
    if (fk.fromKey == selectedKey) {
      out.add(fk.toKey);
    } else if (fk.toKey == selectedKey) {
      out.add(fk.fromKey);
    }
  }
  return out;
}

class GutterItem {
  /// `schema.table` for table rows; `null` for schema headers / non-table rows.
  final String? tableKey;
  const GutterItem({required this.tableKey});
}

class RelationshipGutterPainter extends CustomPainter {
  final List<GutterItem> items;
  final List<ForeignKey> edges;
  final String? selectedKey;
  final ScrollPosition scroll;

  /// Optional per-table colour override built by the sidebar with
  /// adjacent-row collision-avoidance. When present, the painter looks up
  /// colours here so the lines match what the user sees in the row.
  final Map<String, Color>? tableColors;

  RelationshipGutterPainter({
    required this.items,
    required this.edges,
    required this.selectedKey,
    required this.scroll,
    this.tableColors,
  }) : super(repaint: scroll);

  Color _colorFor(String key) => tableColors?[key] ?? colorForTable(key);

  double _yFor(int index) =>
      index * kGutterRowHeight - scroll.pixels + kGutterRowHeight / 2;

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;

    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final keyToIndex = <String, int>{};
    for (var i = 0; i < items.length; i++) {
      final k = items[i].tableKey;
      if (k != null) keyToIndex[k] = i;
    }

    final sorted = _stableSorted(edges);
    final anchorX = size.width - 4;
    final viewportTop = -kGutterRowHeight;
    final viewportBottom = size.height + kGutterRowHeight;

    // Two distinct rendering modes:
    // - selection mode: only edges touching the selected row, drawn in the
    // neighbour's table colour at full strength.
    // - topology mode (nothing selected): every edge, in a neutral grey at
    // very low alpha — visible enough to see structure, faint enough to
    // stay out of the way.
    final incident = <int>[];
    if (selectedKey != null) {
      for (var i = 0; i < sorted.length; i++) {
        final fk = sorted[i];
        if (fk.fromKey == fk.toKey) continue;
        if (fk.fromKey == selectedKey || fk.toKey == selectedKey) {
          incident.add(i);
        }
      }
    }

    // Lane assignment: each drawn line gets its own vertical track so parallel
    // runs sit side-by-side. Lane indices are assigned within the *drawn* set
    // so a typical selection (a handful of edges) spreads across distinct
    // lanes instead of stacking in lane 0.
    const double laneSpacing = 4.0;
    const double laneMin = 3.0;
    const double cornerRadius = 5.0;
    final laneMax = anchorX - cornerRadius;

    void drawLine({
      required int from,
      required int to,
      required int laneIndex,
      required int laneCount,
      required Color colour,
      required double strokeWidth,
    }) {
      final y1 = _yFor(from);
      final y2 = _yFor(to);
      if ((y1 < viewportTop && y2 < viewportTop) ||
          (y1 > viewportBottom && y2 > viewportBottom)) {
        return;
      }
      final cpX = laneMin + (laneIndex % laneCount) * laneSpacing;
      const r = cornerRadius;
      final path = Path()..moveTo(anchorX, y1);
      if ((y2 - y1).abs() < 2 * r) {
        path
          ..lineTo(cpX, y1)
          ..lineTo(cpX, y2)
          ..lineTo(anchorX, y2);
      } else {
        final goingDown = y2 > y1;
        path
          ..lineTo(cpX + r, y1)
          ..quadraticBezierTo(cpX, y1, cpX, goingDown ? y1 + r : y1 - r)
          ..lineTo(cpX, goingDown ? y2 - r : y2 + r)
          ..quadraticBezierTo(cpX, y2, cpX + r, y2)
          ..lineTo(anchorX, y2);
      }
      final paint = Paint()
        ..color = colour
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(path, paint);
    }

    if (selectedKey == null) {
      // Topology mode: faint grey lines for every edge.
      final usable = (laneMax - laneMin) / laneSpacing;
      final laneCount = sorted.isEmpty
          ? 1
          : usable.floor().clamp(1, sorted.length);
      const faint = Color(0x33808080);
      for (var i = 0; i < sorted.length; i++) {
        final fk = sorted[i];
        if (fk.fromKey == fk.toKey) continue;
        final from = keyToIndex[fk.fromKey];
        final to = keyToIndex[fk.toKey];
        if (from == null || to == null) continue;
        drawLine(
          from: from,
          to: to,
          laneIndex: i,
          laneCount: laneCount,
          colour: faint,
          strokeWidth: 1.2,
        );
      }
    } else {
      // Selection mode: bold, neighbour-coloured lines.
      final usable = (laneMax - laneMin) / laneSpacing;
      final laneCount = incident.isEmpty
          ? 1
          : usable.floor().clamp(1, incident.length);
      for (var drawn = 0; drawn < incident.length; drawn++) {
        final i = incident[drawn];
        final fk = sorted[i];
        final from = keyToIndex[fk.fromKey];
        final to = keyToIndex[fk.toKey];
        if (from == null || to == null) continue;
        final other = fk.fromKey == selectedKey ? fk.toKey : fk.fromKey;
        drawLine(
          from: from,
          to: to,
          laneIndex: drawn,
          laneCount: laneCount,
          colour: _colorFor(other),
          strokeWidth: 2.4,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant RelationshipGutterPainter old) {
    return old.items != items ||
        old.edges != edges ||
        old.selectedKey != selectedKey ||
        old.scroll != scroll ||
        old.tableColors != tableColors;
  }
}
