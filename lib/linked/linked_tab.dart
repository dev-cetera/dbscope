/// @docImport '../inspector/property_inspector.dart';
library;

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../catalog/schema_catalog.dart';
import '../db/edit_policy.dart';
import '../grid/data_grid.dart';
import '../navigator/navigator_tab.dart';
import '../query/pager.dart';
import '../shell/app_state.dart';

bool _samePrimaryKey(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One node on the linked canvas. Free-floating, draggable, and either
/// renders a single row (PropertyInspector) or a paginated list of rows
/// that the user can promote to row nodes.
sealed class LinkedNode {
  LinkedNode({
    String? id,
    required this.position,
    this.width = 240,
  }) : id = id ?? const Uuid().v4();
  final String id;
  Offset position;

  /// Canvas-space width of the node card. Defaults to a reasonable
  /// starting size; the view auto-sizes this to fit the widest body row
  /// once columns load, and lets the user further resize by dragging the
  /// right edge.
  double width;
}

/// A single row on the canvas. The node card renders as a compact
/// ER-diagram cell — PK columns plus outbound FK columns — and the full
/// row contents are surfaced in the right-side [PropertyInspector] when
/// the node is selected.
class LinkedRowNode extends LinkedNode {
  LinkedRowNode({
    super.id,
    required super.position,
    super.width,
    required this.schema,
    required this.table,
    required this.pkColumns,
    required this.pkValues,
    this.isSeed = false,
  });
  final String schema;
  final String table;
  final List<String> pkColumns;
  final List<Object?> pkValues;

  /// True iff this node was the entry point for its chain (added from the
  /// left row-picker sidebar). Renders with a flag badge + PK suffix so the
  /// user can tell which row anchored each chain when several share the
  /// canvas.
  bool isSeed;

  Map<String, Object?>? row;

  /// Metadata `display.rowLabel` rendered for [row] ("Buy milk (OPEN)"),
  /// or null. Set with [row]; the card shows it as its subtitle.
  String? rowLabel;
  List<ColumnInfo> columns = const [];
  List<EditPolicy> editPolicies = const [];
  var isLoading = false;
  String? error;

  bool sameRowAs(
    String otherSchema,
    String otherTable,
    List<Object?> otherPrimaryKey,
  ) {
    if (otherSchema != schema || otherTable != table) return false;
    return _samePrimaryKey(pkValues, otherPrimaryKey);
  }

  /// Ordered list of columns the node renders in its body. PK columns
  /// come first (so inbound edges can anchor precisely to the PK row),
  /// followed by outbound FK columns (so outbound edges can anchor to
  /// the FK row). Used by both the node body and the edge painter so
  /// anchor Y positions stay in sync.
  List<String> bodyColumnOrder(List<ForeignKey> allForeignKeys) {
    final out = <String>[];
    final seen = <String>{};
    for (final primaryKey in pkColumns) {
      if (seen.add(primaryKey)) out.add(primaryKey);
    }
    for (final foreignKey in allForeignKeys) {
      if (foreignKey.fromSchema != schema || foreignKey.fromTable != table) {
        continue;
      }
      if (!seen.add(foreignKey.fromColumn)) continue;
      out.add(foreignKey.fromColumn);
    }
    return out;
  }
}

/// A paginated list of rows from a table. The root seed is a list node
/// for the chosen table; inbound-FK clicks on a row node also spawn list
/// nodes (filtered by the inbound FK). Clicking a row inside a list node
/// promotes that row to a [LinkedRowNode] connected by an edge.
class LinkedListNode extends LinkedNode {
  LinkedListNode({
    super.id,
    required super.position,
    super.width,
    required this.schema,
    required this.table,
    this.inboundFilter,
  });
  final String schema;
  final String table;
  final InboundFilter? inboundFilter;

  List<ColumnInfo> columns = const [];
  List<String> pkColumns = const [];
  Set<String> indexedColumns = const {};
  List<EditPolicy> editPolicies = const [];
  var catalogLoaded = false;

  GridData? data;
  KeysetPager? pager;
  var isLoading = false;
  var isLoadingMore = false;
  var hasNextPage = false;
  String? error;
}

/// Inspector-only row reference. Lets the user "peek" at a row in the
/// right-side property inspector without committing it to the canvas as
/// a [LinkedRowNode]. Lives independently of the node list so the canvas
/// stays uncluttered while browsing the middle row-list panel.
class LinkedRowRef {
  LinkedRowRef({
    required this.schema,
    required this.table,
    required this.pkColumns,
    required this.pkValues,
  });
  final String schema;
  final String table;
  final List<String> pkColumns;
  final List<Object?> pkValues;

  Map<String, Object?>? row;
  List<ColumnInfo> columns = const [];
  List<EditPolicy> editPolicies = const [];
  var isLoading = false;
  String? error;

  bool sameRowAs(
    String otherSchema,
    String otherTable,
    List<Object?> otherPrimaryKey,
  ) {
    if (otherSchema != schema || otherTable != table) return false;
    return _samePrimaryKey(pkValues, otherPrimaryKey);
  }
}

/// Connector between two nodes. [fromColumn] is the FK column on the
/// referencing (source) node; [toColumn] is the referenced PK/unique
/// column on the target node. The edge painter uses these to anchor
/// the endpoints to the exact column rows inside each card.
class LinkedEdge {
  const LinkedEdge({
    required this.fromNodeId,
    required this.toNodeId,
    this.fromColumn,
    this.toColumn,
    this.incoming = false,
  });
  final String fromNodeId;
  final String toNodeId;
  final String? fromColumn;
  final String? toColumn;
  final bool incoming;
}

/// Canvas-style tab that renders a row plus its FK-linked rows as a web
/// of draggable PropertyInspector nodes. Foreign-key catalog is loaded
/// once and reused for every node so chips render without per-node round
/// trips.
class LinkedTab extends TabModel {
  LinkedTab({
    super.id,
    required super.connectionId,
    this.seedSchema,
    this.seedTable,
  }) : pickerSchema = seedSchema,
       pickerTable = seedTable;
  final List<LinkedNode> nodes = [];
  final List<LinkedEdge> edges = [];

  List<ForeignKey> foreignKeys = const [];
  var fksLoaded = false;
  String? fksError;

  /// Pan offset applied to the entire canvas. Persisted on the tab so
  /// switching away and back keeps the view where the user left it.
  Offset pan = Offset.zero;

  /// Zoom factor applied to the canvas. 1.0 = no scaling. Persisted so
  /// switching tabs keeps the zoom level the user set.
  var scale = 1.0;

  /// Set when the tab was opened with a target table but no seed row yet
  /// (e.g. from the sidebar context menu). The view uses this to seed the
  /// row-picker side panel.
  final String? seedSchema;
  final String? seedTable;

  /// Table currently selected in the left-side row-picker panel. Mutated
  /// when the user picks a different table from the panel's table button.
  String? pickerSchema;
  String? pickerTable;

  /// Node currently selected on the canvas. The right-side property
  /// inspector renders the row for this node; null = nothing selected.
  String? selectedNodeId;

  /// Inspector preview row, populated when the user taps a row in the
  /// middle row-list panel. When non-null, the right inspector renders
  /// this row instead of the selected node's row — lets the user browse
  /// rows of the selected table without spawning a node per tap.
  LinkedRowRef? previewRow;

  /// Width in pixels of the middle row-list panel (between the canvas and
  /// the right inspector). Persisted on the tab so it survives switching
  /// away and back.
  double middlePanelWidth = 280;

  /// User toggles for hiding the left seed-picker panel and the middle
  /// preview-picker panel. Per-tab so opening another linked tab keeps
  /// its own layout. Right inspector visibility is shared via
  /// [AppState.propertyInspectorCollapsed] and stays global.
  var leftPickerCollapsed = false;
  var middlePanelCollapsed = false;

  @override
  String get title {
    if (nodes.isEmpty) {
      if (seedTable != null) return 'Linked: $seedTable';
      return 'Linked view';
    }
    final root = nodes.first;
    if (root is LinkedRowNode) return 'Linked: ${root.table}';
    if (root is LinkedListNode) return 'Linked: ${root.table}';
    return 'Linked view';
  }

  /// True iff the canvas already has a row node for the same PK tuple —
  /// used by the view to focus an existing node instead of opening a
  /// duplicate.
  LinkedRowNode? findRow(String schema, String table, List<Object?> pkValues) {
    for (final node in nodes) {
      if (node is LinkedRowNode && node.sameRowAs(schema, table, pkValues)) {
        return node;
      }
    }
    return null;
  }

  LinkedListNode? findList(
    String schema,
    String table, {
    String? inboundConstraintKey,
  }) {
    for (final node in nodes) {
      if (node is! LinkedListNode) continue;
      if (node.schema != schema || node.table != table) continue;
      final cKey = node.inboundFilter?.constraintKey;
      if (cKey == inboundConstraintKey) return node;
    }
    return null;
  }

  void removeNode(String id) {
    nodes.removeWhere((node) => node.id == id);
    edges.removeWhere((e) => e.fromNodeId == id || e.toNodeId == id);
    if (selectedNodeId == id) selectedNodeId = null;
  }

  /// Ids of every node reachable from [startId] via edges treated as
  /// undirected — i.e. the connected component containing [startId].
  /// Used by "Remove chain" so picking any node in a chain drops the
  /// whole chain.
  Set<String> connectedComponentOf(String startId) {
    final byId = {for (final node in nodes) node.id};
    if (!byId.contains(startId)) return const {};
    final adj = <String, Set<String>>{
      for (final id in byId) id: <String>{},
    };
    for (final e in edges) {
      if (!byId.contains(e.fromNodeId) || !byId.contains(e.toNodeId)) continue;
      adj[e.fromNodeId]!.add(e.toNodeId);
      adj[e.toNodeId]!.add(e.fromNodeId);
    }
    final out = <String>{};
    final queue = <String>[startId];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!out.add(current)) continue;
      for (final neighbourId in adj[current] ?? const <String>{}) {
        if (!out.contains(neighbourId)) queue.add(neighbourId);
      }
    }
    return out;
  }

  /// Drops the entire connected component containing [startId]. Cleans up
  /// edges, the selection and the preview row if they referenced any of
  /// the removed nodes.
  void removeChain(String startId) {
    final ids = connectedComponentOf(startId);
    if (ids.isEmpty) return;
    nodes.removeWhere((node) => ids.contains(node.id));
    edges.removeWhere(
      (e) => ids.contains(e.fromNodeId) || ids.contains(e.toNodeId),
    );
    if (selectedNodeId != null && ids.contains(selectedNodeId)) {
      selectedNodeId = null;
    }
  }

  LinkedRowNode? get selectedRowNode {
    final id = selectedNodeId;
    if (id == null) return null;
    for (final node in nodes) {
      if (node.id == id && node is LinkedRowNode) return node;
    }
    return null;
  }
}
