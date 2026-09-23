import 'dart:math' as math;
import 'package:flutter/widgets.dart';

import 'schema_model.dart';

/// Default fixed card width. The view auto-fits to the widest row at
/// first paint and the user can drag to override.
const double kSchemaNodeWidth = 260;
const double kSchemaRowHeight = 22;
const double kSchemaHeaderHeight = 34;
const double kSchemaSubtitleHeight = 18;

/// Empty-card height (header only) when compact-mode hides every field.
const double kSchemaEmptyBodyHeight = 22;

/// Min/max dragging the right edge can clamp a card to.
const double kSchemaNodeMinWidth = 180;
const double kSchemaNodeMaxWidth = 480;

/// Padding around every node's AABB used for separation and the dagre
/// rest length, so cards never end up touching.
const double kSchemaNodeMargin = 32;

double schemaNodeHeight(int visibleFieldCount, {bool hasSubtitle = false}) {
  final body = visibleFieldCount == 0
      ? kSchemaEmptyBodyHeight
      : visibleFieldCount * kSchemaRowHeight;
  final extra = hasSubtitle ? kSchemaSubtitleHeight : 0;
  return kSchemaHeaderHeight + extra + body;
}

int visibleFieldCountFor(SchemaNodeData n, {bool compact = false}) {
  if (!compact) return n.fields.length;
  return n.fields.where((f) => f.pk || f.fk || f.isRefTarget).length;
}

double renderedNodeHeight(SchemaNodeData n) {
  return schemaNodeHeight(
    visibleFieldCountFor(n, compact: n.compact),
    hasSubtitle: n.subtitle != null,
  );
}

double effectiveNodeWidth(SchemaNodeData n) {
  if (n.widthOverridden && n.widthOverride != null) return n.widthOverride!;
  return kSchemaNodeWidth;
}

/// Layout direction the diagram should arrange itself in.
enum SchemaLayoutMode { lr, tb }

/// Public entry point. Mutates [nodes]' positions and returns the
/// AABB-bounding canvas size for fit-view math.
Size layoutSchemaNodes(
  List<SchemaNodeData> nodes,
  List<SchemaEdgeData> edges, {
  SchemaLayoutMode mode = SchemaLayoutMode.lr,
  double colGap = 80,
  double rowGap = 24,
}) {
  if (nodes.isEmpty) return Size.zero;
  if (edges.isEmpty) {
    return _layoutGrid(nodes, colGap: colGap, rowGap: rowGap);
  }
  return _layoutRanked(
    nodes,
    edges,
    mode: mode,
    colGap: colGap,
    rowGap: rowGap,
  );
}

/// Falls back when the graph has no edges — square-ish grid placement.
Size _layoutGrid(
  List<SchemaNodeData> nodes, {
  required double colGap,
  required double rowGap,
}) {
  final cols = math.max(1, math.sqrt(nodes.length).ceil());
  double x = 0;
  double y = 0;
  double rowHMax = 0;
  int col = 0;
  double maxX = 0;
  double maxY = 0;
  for (final n in nodes) {
    final w = effectiveNodeWidth(n);
    final h = renderedNodeHeight(n);
    n.position = Offset(x, y);
    rowHMax = math.max(rowHMax, h);
    maxX = math.max(maxX, x + w);
    maxY = math.max(maxY, y + h);
    col += 1;
    if (col >= cols) {
      col = 0;
      x = 0;
      y += rowHMax + rowGap;
      rowHMax = 0;
    } else {
      x += w + colGap;
    }
  }
  return Size(maxX, maxY);
}

/// Sugiyama-style ranked layout. Roughly the same shape dagre produces
/// for typical schemas: roots on the left/top, leaves on the right/bottom,
/// barycentric ordering inside each rank to reduce edge crossings.
Size _layoutRanked(
  List<SchemaNodeData> nodes,
  List<SchemaEdgeData> edges, {
  required SchemaLayoutMode mode,
  required double colGap,
  required double rowGap,
}) {
  final ids = nodes.map((n) => n.id).toSet();
  final node = {for (final n in nodes) n.id: n};

  // adjacency, skipping self-edges and edges to/from missing nodes
  final outAdj = <String, List<String>>{for (final id in ids) id: []};
  final inAdj = <String, List<String>>{for (final id in ids) id: []};
  for (final e in edges) {
    if (e.sourceId == e.targetId) continue;
    if (!ids.contains(e.sourceId) || !ids.contains(e.targetId)) continue;
    outAdj[e.sourceId]!.add(e.targetId);
    inAdj[e.targetId]!.add(e.sourceId);
  }

  // Rank via longest path from source nodes (no incoming).
  final rank = <String, int>{};
  final visited = <String, bool>{};
  void assignRank(String id) {
    if (visited[id] == true) return;
    visited[id] = true;
    int best = 0;
    for (final p in inAdj[id]!) {
      // Ignore back-edges (DFS cycle): if we'd recurse into a node already
      // on the stack, skip it. visited[..]==null means not seen; ==true
      // means we just landed here in this assignRank call.
      if (visited[p] == null) assignRank(p);
      final rp = rank[p];
      if (rp != null && rp + 1 > best) best = rp + 1;
    }
    rank[id] = best;
  }

  for (final id in ids) {
    assignRank(id);
  }

  // Bucket nodes by rank.
  final buckets = <int, List<String>>{};
  int maxRank = 0;
  for (final entry in rank.entries) {
    buckets.putIfAbsent(entry.value, () => []).add(entry.key);
    if (entry.value > maxRank) maxRank = entry.value;
  }

  // 1 sweep of barycentric ordering (top -> bottom) using parents'
  // already-assigned indexes. Reduces crossings without a full
  // 2-sweep heuristic; for schemas this is good enough.
  final order = <int, List<String>>{};
  for (var r = 0; r <= maxRank; r++) {
    final layer = (buckets[r] ?? const <String>[]).toList();
    if (r == 0) {
      layer.sort();
      order[r] = layer;
      continue;
    }
    final prev = order[r - 1] ?? const [];
    final prevIdx = {for (var i = 0; i < prev.length; i++) prev[i]: i};
    double barycentre(String id) {
      final parents = inAdj[id]!;
      double sum = 0;
      int count = 0;
      for (final p in parents) {
        final i = prevIdx[p];
        if (i != null) {
          sum += i.toDouble();
          count += 1;
        }
      }
      if (count == 0) return prev.length / 2.0;
      return sum / count;
    }

    layer.sort((a, b) {
      final c = barycentre(a).compareTo(barycentre(b));
      if (c != 0) return c;
      return a.compareTo(b);
    });
    order[r] = layer;
  }

  // Coordinate assignment. LR = ranks across X, positions across Y.
  // TB = ranks across Y, positions across X.
  final positions = <String, Offset>{};
  if (mode == SchemaLayoutMode.lr) {
    double x = 0;
    for (var r = 0; r <= maxRank; r++) {
      final layer = order[r] ?? const [];
      double rankWidth = 0;
      for (final id in layer) {
        rankWidth = math.max(rankWidth, effectiveNodeWidth(node[id]!));
      }
      double y = 0;
      for (final id in layer) {
        final w = effectiveNodeWidth(node[id]!);
        final h = renderedNodeHeight(node[id]!);
        final cx = x + (rankWidth - w) / 2;
        positions[id] = Offset(cx, y);
        y += h + rowGap;
      }
      x += rankWidth + colGap;
    }
  } else {
    double y = 0;
    for (var r = 0; r <= maxRank; r++) {
      final layer = order[r] ?? const [];
      double rankHeight = 0;
      for (final id in layer) {
        rankHeight = math.max(rankHeight, renderedNodeHeight(node[id]!));
      }
      double x = 0;
      for (final id in layer) {
        final w = effectiveNodeWidth(node[id]!);
        final h = renderedNodeHeight(node[id]!);
        final cy = y + (rankHeight - h) / 2;
        positions[id] = Offset(x, cy);
        x += w + colGap;
      }
      y += rankHeight + rowGap;
    }
  }

  // Apply, compute bounding box.
  double maxX = 0;
  double maxY = 0;
  for (final n in nodes) {
    final p = positions[n.id] ?? Offset.zero;
    n.position = p;
    final w = effectiveNodeWidth(n);
    final h = renderedNodeHeight(n);
    maxX = math.max(maxX, p.dx + w);
    maxY = math.max(maxY, p.dy + h);
  }
  return Size(maxX, maxY);
}

/// Cascading AABB separation used by the canvas when a node moves
/// (drag) or grows (expand). [movedIds] are immovable; their positions
/// are authoritative. Mutates [positions] in place and returns the set
/// of node ids whose position changed. Mirrors admin_site/dbmlLayout.ts
/// cascadeSeparate.
Set<String> cascadeSeparate({
  required Set<String> movedIds,
  required Map<String, Offset> positions,
  required ({double w, double h})? Function(String id) dimsFor,
  required Iterable<String> allIds,
  int maxPasses = 8,
}) {
  final changed = <String>{};
  Set<String> work = Set<String>.of(movedIds);
  for (var pass = 0; pass < maxPasses; pass++) {
    final next = <String>{};
    for (final id in work) {
      final a = positions[id];
      final da = dimsFor(id);
      if (a == null || da == null) continue;
      for (final otherId in allIds) {
        if (otherId == id) continue;
        if (movedIds.contains(otherId)) continue;
        final b = positions[otherId];
        final db = dimsFor(otherId);
        if (b == null || db == null) continue;
        final minDx = (da.w + db.w) / 2 + kSchemaNodeMargin;
        final minDy = (da.h + db.h) / 2 + kSchemaNodeMargin;
        final dx = (b.dx + db.w / 2) - (a.dx + da.w / 2);
        final dy = (b.dy + db.h / 2) - (a.dy + da.h / 2);
        final ox = minDx - dx.abs();
        final oy = minDy - dy.abs();
        if (ox <= 0 || oy <= 0) continue;
        if (ox < oy) {
          final push = ox + 0.5;
          positions[otherId] = Offset(b.dx + (dx >= 0 ? push : -push), b.dy);
        } else {
          final push = oy + 0.5;
          positions[otherId] = Offset(b.dx, b.dy + (dy >= 0 ? push : -push));
        }
        changed.add(otherId);
        next.add(otherId);
      }
    }
    if (next.isEmpty) break;
    work = next;
  }
  return changed;
}

/// AABB rectangle for a node, used by the edge painter and the side-
/// picker.
Rect rectForNode(SchemaNodeData n) {
  return Rect.fromLTWH(
    n.position.dx,
    n.position.dy,
    effectiveNodeWidth(n),
    renderedNodeHeight(n),
  );
}

/// Local-Y offset for the row holding [columnName], so edges can anchor
/// at the exact row centre instead of the card rim. Returns null when the
/// column isn't actually rendered (compact mode hiding a non-PK/FK
/// column).
double? columnLocalCentreY(SchemaNodeData n, String columnName) {
  final visible = <SchemaFieldSpec>[];
  for (final f in n.fields) {
    if (!n.compact || f.pk || f.fk || f.isRefTarget) visible.add(f);
  }
  final idx = visible.indexWhere((f) => f.name == columnName);
  if (idx < 0) return null;
  final headerOffset =
      kSchemaHeaderHeight + (n.subtitle != null ? kSchemaSubtitleHeight : 0);
  return headerOffset + idx * kSchemaRowHeight + kSchemaRowHeight / 2;
}

/// Per-edge side picker. For each edge with [SchemaEdgeData.sourceField]
/// and [SchemaEdgeData.targetField], records whether the source-side
/// endpoint sits on the right or left rim, so the curve bends toward
/// whichever side is closer to the target. Returns a map keyed by edge id.
Map<String, ({bool sourceOnRight, bool targetOnRight})> pickEdgeSides(
  List<SchemaEdgeData> edges,
  ({double x, double y, double w, double h})? Function(String id) dimsFor,
) {
  final out = <String, ({bool sourceOnRight, bool targetOnRight})>{};
  for (final e in edges) {
    final s = dimsFor(e.sourceId);
    final t = dimsFor(e.targetId);
    if (s == null || t == null) continue;
    final sy = s.y + s.h / 2;
    final ty = t.y + t.h / 2;
    final sRight = s.x + s.w;
    final sLeft = s.x;
    final tRight = t.x + t.w;
    final tLeft = t.x;
    final distRtoL =
        math.sqrt(math.pow(tLeft - sRight, 2) + math.pow(ty - sy, 2));
    final distLtoR =
        math.sqrt(math.pow(tRight - sLeft, 2) + math.pow(ty - sy, 2));
    final sourceOnRight = distRtoL <= distLtoR;
    out[e.id] = (sourceOnRight: sourceOnRight, targetOnRight: !sourceOnRight);
  }
  return out;
}
