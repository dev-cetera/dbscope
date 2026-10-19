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
  final body =
      visibleFieldCount == 0 ? kSchemaEmptyBodyHeight : visibleFieldCount * kSchemaRowHeight;
  final extra = hasSubtitle ? kSchemaSubtitleHeight : 0;
  return kSchemaHeaderHeight + extra + body;
}

int visibleFieldCountFor(SchemaNodeData node, {bool compact = false}) {
  if (!compact) return node.fields.length;
  return node.fields.where((field) => field.pk || field.fk || field.isRefTarget).length;
}

double renderedNodeHeight(SchemaNodeData node) {
  return schemaNodeHeight(
    visibleFieldCountFor(node, compact: node.compact),
    hasSubtitle: node.subtitle != null,
  );
}

double effectiveNodeWidth(SchemaNodeData node) {
  if (node.widthOverridden && node.widthOverride != null) {
    return node.widthOverride!;
  }
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
  final columnCount = math.max(1, math.sqrt(nodes.length).ceil());
  double x = 0;
  double y = 0;
  double rowHMax = 0;
  var column = 0;
  double maxX = 0;
  double maxY = 0;
  for (final node in nodes) {
    final width = effectiveNodeWidth(node);
    final height = renderedNodeHeight(node);
    node.position = Offset(x, y);
    rowHMax = math.max(rowHMax, height);
    maxX = math.max(maxX, x + width);
    maxY = math.max(maxY, y + height);
    column += 1;
    if (column >= columnCount) {
      column = 0;
      x = 0;
      y += rowHMax + rowGap;
      rowHMax = 0;
    } else {
      x += width + colGap;
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
  final ids = nodes.map((node) => node.id).toSet();
  final nodeById = {for (final node in nodes) node.id: node};

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
    if (visited[id] ?? false) return;
    visited[id] = true;
    var best = 0;
    for (final parent in inAdj[id]!) {
      // Ignore back-edges (DFS cycle): if we'd recurse into a node already
      // on the stack, skip it. visited[..]==null means not seen; ==true
      // means we just landed here in this assignRank call.
      if (visited[parent] == null) assignRank(parent);
      final rp = rank[parent];
      if (rp != null && rp + 1 > best) best = rp + 1;
    }
    rank[id] = best;
  }

  ids.forEach(assignRank);

  // Bucket nodes by rank.
  final buckets = <int, List<String>>{};
  var maxRank = 0;
  for (final entry in rank.entries) {
    buckets.putIfAbsent(entry.value, () => []).add(entry.key);
    if (entry.value > maxRank) maxRank = entry.value;
  }

  // 1 sweep of barycentric ordering (top -> bottom) using parents'
  // already-assigned indexes. Reduces crossings without a full
  // 2-sweep heuristic; for schemas this is good enough.
  final order = <int, List<String>>{};
  for (var rankIndex = 0; rankIndex <= maxRank; rankIndex++) {
    final layer = (buckets[rankIndex] ?? const <String>[]).toList();
    if (rankIndex == 0) {
      layer.sort();
      order[rankIndex] = layer;
      continue;
    }
    final previousLayer = order[rankIndex - 1] ?? const [];
    final previousIndex = {
      for (var i = 0; i < previousLayer.length; i++) previousLayer[i]: i,
    };
    double barycentre(String id) {
      final parents = inAdj[id]!;
      double sum = 0;
      var count = 0;
      for (final parent in parents) {
        final i = previousIndex[parent];
        if (i != null) {
          sum += i.toDouble();
          count += 1;
        }
      }
      if (count == 0) return previousLayer.length / 2.0;
      return sum / count;
    }

    layer.sort((a, b) {
      final comparison = barycentre(a).compareTo(barycentre(b));
      if (comparison != 0) return comparison;
      return a.compareTo(b);
    });
    order[rankIndex] = layer;
  }

  // Coordinate assignment. LR = ranks across X, positions across Y.
  // TB = ranks across Y, positions across X.
  final positions = <String, Offset>{};
  if (mode == SchemaLayoutMode.lr) {
    double x = 0;
    for (var rankIndex = 0; rankIndex <= maxRank; rankIndex++) {
      final layer = order[rankIndex] ?? const [];
      double rankWidth = 0;
      for (final id in layer) {
        rankWidth = math.max(rankWidth, effectiveNodeWidth(nodeById[id]!));
      }
      double y = 0;
      for (final id in layer) {
        final width = effectiveNodeWidth(nodeById[id]!);
        final height = renderedNodeHeight(nodeById[id]!);
        final cx = x + (rankWidth - width) / 2;
        positions[id] = Offset(cx, y);
        y += height + rowGap;
      }
      x += rankWidth + colGap;
    }
  } else {
    double y = 0;
    for (var rankIndex = 0; rankIndex <= maxRank; rankIndex++) {
      final layer = order[rankIndex] ?? const [];
      double rankHeight = 0;
      for (final id in layer) {
        rankHeight = math.max(rankHeight, renderedNodeHeight(nodeById[id]!));
      }
      double x = 0;
      for (final id in layer) {
        final width = effectiveNodeWidth(nodeById[id]!);
        final height = renderedNodeHeight(nodeById[id]!);
        final cy = y + (rankHeight - height) / 2;
        positions[id] = Offset(x, cy);
        x += width + colGap;
      }
      y += rankHeight + rowGap;
    }
  }

  // Apply, compute bounding box.
  double maxX = 0;
  double maxY = 0;
  for (final node in nodes) {
    final position = positions[node.id] ?? Offset.zero;
    node.position = position;
    final width = effectiveNodeWidth(node);
    final height = renderedNodeHeight(node);
    maxX = math.max(maxX, position.dx + width);
    maxY = math.max(maxY, position.dy + height);
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
  var work = Set<String>.of(movedIds);
  for (var pass = 0; pass < maxPasses; pass++) {
    final next = <String>{};
    for (final id in work) {
      final aPosition = positions[id];
      final da = dimsFor(id);
      if (aPosition == null || da == null) continue;
      for (final otherId in allIds) {
        if (otherId == id) continue;
        if (movedIds.contains(otherId)) continue;
        final bPosition = positions[otherId];
        final db = dimsFor(otherId);
        if (bPosition == null || db == null) continue;
        final minDx = (da.w + db.w) / 2 + kSchemaNodeMargin;
        final minDy = (da.h + db.h) / 2 + kSchemaNodeMargin;
        final dx = (bPosition.dx + db.w / 2) - (aPosition.dx + da.w / 2);
        final dy = (bPosition.dy + db.h / 2) - (aPosition.dy + da.h / 2);
        final ox = minDx - dx.abs();
        final oy = minDy - dy.abs();
        if (ox <= 0 || oy <= 0) continue;
        if (ox < oy) {
          final push = ox + 0.5;
          positions[otherId] = Offset(
            bPosition.dx + (dx >= 0 ? push : -push),
            bPosition.dy,
          );
        } else {
          final push = oy + 0.5;
          positions[otherId] = Offset(
            bPosition.dx,
            bPosition.dy + (dy >= 0 ? push : -push),
          );
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
Rect rectForNode(SchemaNodeData node) {
  return Rect.fromLTWH(
    node.position.dx,
    node.position.dy,
    effectiveNodeWidth(node),
    renderedNodeHeight(node),
  );
}

/// Local-Y offset for the row holding [columnName], so edges can anchor
/// at the exact row centre instead of the card rim. Returns null when the
/// column isn't actually rendered (compact mode hiding a non-PK/FK
/// column).
double? columnLocalCentreY(SchemaNodeData node, String columnName) {
  final visible = <SchemaFieldSpec>[];
  for (final field in node.fields) {
    if (!node.compact || field.pk || field.fk || field.isRefTarget) {
      visible.add(field);
    }
  }
  final index = visible.indexWhere((field) => field.name == columnName);
  if (index < 0) return null;
  final headerOffset = kSchemaHeaderHeight + (node.subtitle != null ? kSchemaSubtitleHeight : 0);
  return headerOffset + index * kSchemaRowHeight + kSchemaRowHeight / 2;
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
    final source = dimsFor(e.sourceId);
    final target = dimsFor(e.targetId);
    if (source == null || target == null) continue;
    final sy = source.y + source.h / 2;
    final ty = target.y + target.h / 2;
    final sRight = source.x + source.w;
    final sLeft = source.x;
    final tRight = target.x + target.w;
    final tLeft = target.x;
    final distRtoL = math.sqrt(math.pow(tLeft - sRight, 2) + math.pow(ty - sy, 2));
    final distLtoR = math.sqrt(math.pow(tRight - sLeft, 2) + math.pow(ty - sy, 2));
    final sourceOnRight = distRtoL <= distLtoR;
    out[e.id] = (sourceOnRight: sourceOnRight, targetOnRight: !sourceOnRight);
  }
  return out;
}
