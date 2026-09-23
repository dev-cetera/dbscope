library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import 'package:schema_viewer/schema_viewer.dart';

import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../connection/registry.dart';
import '../db/executor.dart';
import '../grid/data_grid.dart';
import '../db/dml.dart';
import '../db/edit_policy.dart';
import '../inspector/grid_with_inspector.dart';
import '../inspector/property_inspector.dart';
import '../query/pager.dart';
import '../shell/app_state.dart';
import '../util/pg_errors.dart';
import '../util/sql_quote.dart';
import 'linked_tab.dart';

part 'parts/canvas.dart';
part 'parts/edge_painter.dart';
part 'parts/node_shell.dart';
part 'parts/row_picker_panel.dart';

/// Default starting width for a freshly created node. The view immediately
/// recomputes a per-node width that fits the actual content; this is just
/// the seed value before columns load.
const double _kDefaultNodeWidth = 260;
const double _kMinNodeWidth = 180;
const double _kMaxAutoWidth = 520;

/// Header / row / subtitle heights mirror the shared SchemaCard so the
/// edge painter anchors lines on the same Y positions the card renders
/// — keep these in lockstep with kSchemaHeaderHeight / kSchemaRowHeight
/// / kSchemaSubtitleHeight in lib/schema/schema_layout.dart.
const double _kHeaderHeight = kSchemaHeaderHeight;
const double _kRowHeight = kSchemaRowHeight;
const double _kSubtitleHeight = kSchemaSubtitleHeight;
const double _kHorizontalGap = 80;
const double _kVerticalGap = 24;
const double _kResizeHandleWidth = 6;
const int _kListPageSize = 200;

/// Rendered height for a row node — header + optional seed-subtitle +
/// one row per visible column. Cards render in compact mode (PK / FK /
/// ref-target rows only), so [_compactColumnsFor] is what drives both
/// height and edge-anchor math.
double _nodeHeightFor(LinkedRowNode node, List<ForeignKey> allFks) {
  final hasSubtitle = node.isSeed && node.pkColumns.isNotEmpty;
  final cols = _compactColumnsFor(node, allFks).length;
  return schemaNodeHeight(cols, hasSubtitle: hasSubtitle);
}

/// Y position (canvas-space, relative to a node's top) of the centre of
/// the row holding [columnName]. Used by the edge painter to anchor
/// endpoints to the exact field row.
double? _columnAnchorYFor(
  LinkedRowNode node,
  List<ForeignKey> allFks,
  String? columnName,
) {
  if (columnName == null) return null;
  final hasSubtitle = node.isSeed && node.pkColumns.isNotEmpty;
  final cols = _compactColumnsFor(node, allFks);
  final idx = cols.indexOf(columnName);
  if (idx < 0) return null;
  final headerOffset = _kHeaderHeight + (hasSubtitle ? _kSubtitleHeight : 0);
  return headerOffset + idx * _kRowHeight + _kRowHeight / 2;
}

/// Per-table colour used in the sidebar's relationship gutter. Linked-view
/// nodes outline themselves with this and edges use the destination node's
/// colour so visual identity is consistent between the two views.
Color _colorForNode(LinkedNode n) {
  if (n is LinkedRowNode) return colorForTable('${n.schema}.${n.table}');
  if (n is LinkedListNode) return colorForTable('${n.schema}.${n.table}');
  return Colors.grey;
}

/// Compute a width that fits the widest row in [node]'s body without
/// truncating. Uses TextPainter so fonts + sizes match what actually
/// renders. Clamped to a sane min/max so a runaway-long column name
/// can't push the node off-screen — the user can drag the right edge
/// to grow it further.
double _autoWidthFor(LinkedRowNode node, List<ForeignKey> fks) {
  const headerStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700);
  const subtitleStyle = TextStyle(fontSize: 11, fontFamily: 'Menlo');
  const nameStyle = TextStyle(fontSize: 12);
  const typeStyle = TextStyle(fontSize: 11, fontFamily: 'Menlo');

  double measure(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  // Header: table name + (optional) seed flag + the two header buttons.
  double widest = measure(node.table, headerStyle) + (node.isSeed ? 18 : 0);
  // Two 20-px header buttons (open + compact) live in the SchemaCard
  // header; reserve their width so the title doesn't truncate.
  widest += 50;

  // Subtitle (pk=val ...).
  if (node.isSeed && node.pkColumns.isNotEmpty) {
    final parts = <String>[];
    for (var i = 0; i < node.pkColumns.length; i++) {
      final v = i < node.pkValues.length ? node.pkValues[i] : null;
      final s = v?.toString() ?? 'NULL';
      parts.add(
        '${node.pkColumns[i]}=${s.length > 24 ? '${s.substring(0, 24)}…' : s}',
      );
    }
    final subtitle = '(${parts.join(', ')})';
    final sw = measure(subtitle, subtitleStyle);
    if (sw > widest) widest = sw;
  }

  // Body rows: name on the left, type-or-value on the right.
  final cols = node.columns.isNotEmpty
      ? [for (final c in node.columns) (name: c.name, type: c.typeName)]
      : [for (final c in node.bodyColumnOrder(fks)) (name: c, type: '')];
  for (final c in cols) {
    final right = node.row != null
        ? (() {
            final v = node.row?[c.name];
            if (v == null) return 'NULL';
            final s = v.toString();
            return s.length > 32 ? '${s.substring(0, 32)}…' : s;
          })()
        : c.type;
    // 8px gap between left + right, plus prefix glyph ("* "/"+ ") width.
    final w = measure(c.name, nameStyle) + 12 + measure(right, typeStyle) + 8;
    if (w > widest) widest = w;
  }

  // Card padding (10 + 10) and a little breathing room.
  final raw = widest + 22;
  return raw.clamp(_kMinNodeWidth, _kMaxAutoWidth);
}

class LinkedTabView extends StatefulWidget {
  final LinkedTab tab;
  const LinkedTabView({super.key, required this.tab});

  @override
  State<LinkedTabView> createState() => _LinkedTabViewState();
}

class _LinkedTabViewState extends State<LinkedTabView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadFKs();
      _bootstrapSeedIfNeeded();
    });
  }

  DbExecutor? _conn() =>
      ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _loadFKs() async {
    final tab = widget.tab;
    if (tab.fksLoaded) return;
    final conn = _conn();
    if (conn == null) {
      tab.fksError = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    try {
      final fks = await SchemaCatalog(conn).listForeignKeys();
      tab.foreignKeys = fks;
      tab.fksLoaded = true;
      tab.fksError = null;
    } catch (e) {
      tab.fksError = classify(e).message;
    }
    if (mounted) AppState.instance.notifyChange();
  }

  void _bootstrapSeedIfNeeded() {
    // No-op: the seed table is now the initial picker table; we don't
    // drop any node on the canvas until the user picks a row in the
    // sidebar. Left here as a hook so seedSchema/seedTable still carry
    // semantic meaning (initial picker table).
  }

  /// Sidebar row-picker callback. Adds a [LinkedRowNode] at the next free
  /// canvas slot, selects it (so the right-side inspector immediately
  /// shows the row), and triggers `_loadRowNode` which auto-expands FK
  /// neighbours.
  void _addRowFromSidebar({
    required String schema,
    required String table,
    required List<String> pkCols,
    required List<Object?> pkValues,
  }) {
    final tab = widget.tab;
    final existing = tab.findRow(schema, table, pkValues);
    if (existing != null) {
      tab.selectedNodeId = existing.id;
      AppState.instance.notifyChange();
      return;
    }
    // Place the new node somewhere visible — to the right of the right-
    // most existing node if any, otherwise origin.
    Offset position = const Offset(60, 60);
    if (tab.nodes.isNotEmpty) {
      final maxRight = tab.nodes
          .map((n) => n.position.dx)
          .reduce((a, b) => a > b ? a : b);
      // Use the right-most node's width to space the new one.
      final rightMost = tab.nodes.reduce(
        (a, b) => a.position.dx > b.position.dx ? a : b,
      );
      position = Offset(maxRight + rightMost.width + _kHorizontalGap, 60);
    }
    final node = LinkedRowNode(
      position: position,
      schema: schema,
      table: table,
      pkColumns: pkCols,
      pkValues: pkValues,
      isSeed: true,
    );
    tab.nodes.add(node);
    tab.selectedNodeId = node.id;
    tab.previewRow = null;
    AppState.instance.notifyChange();
    _loadRowNode(node);
  }

  /// Drops the connected component containing [node] from the canvas.
  /// Triggered from the per-node right-click context menu — picking any
  /// node in a chain removes the whole chain.
  void _removeChain(LinkedNode node) {
    widget.tab.removeChain(node.id);
    AppState.instance.notifyChange();
  }

  Future<void> _showNodeContextMenu(LinkedNode node, Offset globalPos) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        globalPos.dx + 1,
        globalPos.dy + 1,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'remove_chain',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.scatter_plot_outlined, size: 16),
              SizedBox(width: 8),
              Text('Remove chain'),
            ],
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (selected == 'remove_chain') _removeChain(node);
  }

  /// Tap-in-the-middle-list handler. Sets the inspector preview to a
  /// row the user is browsing, without spawning a node on the canvas.
  /// If the row is already the selected node, just clears the preview so
  /// the inspector falls back to that node.
  void _previewRowFromList({
    required String schema,
    required String table,
    required List<String> pkCols,
    required List<Object?> pkValues,
  }) {
    final tab = widget.tab;
    final selected = tab.selectedRowNode;
    if (selected != null && selected.sameRowAs(schema, table, pkValues)) {
      if (tab.previewRow != null) {
        tab.previewRow = null;
        AppState.instance.notifyChange();
      }
      return;
    }
    final ref = LinkedRowRef(
      schema: schema,
      table: table,
      pkColumns: pkCols,
      pkValues: pkValues,
    );
    tab.previewRow = ref;
    AppState.instance.notifyChange();
    _loadPreviewRow(ref);
  }

  Future<void> _loadPreviewRow(LinkedRowRef ref) async {
    final conn = _conn();
    if (conn == null) {
      ref.error = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    ref.isLoading = true;
    ref.error = null;
    AppState.instance.notifyChange();
    try {
      final catalog = SchemaCatalog(conn);
      final cols = await catalog.listColumns(ref.schema, ref.table);
      final pk = await catalog.primaryKey(ref.schema, ref.table);
      final values = <Object?>[];
      for (final c in pk) {
        final i = ref.pkColumns.indexOf(c);
        values.add(i >= 0 ? ref.pkValues[i] : null);
      }
      final row = await catalog.loadRowByPk(
        schema: ref.schema,
        table: ref.table,
        pkColumns: pk,
        pkValues: values,
      );
      if (!mounted) return;
      // The preview may have been replaced or cleared while we awaited —
      // discard this load so we don't paint stale data over a newer one.
      if (widget.tab.previewRow != ref) return;
      ref.columns = cols;
      ref.editPolicies = [
        for (final c in cols)
          EditPolicy(
            schema: ref.schema,
            table: ref.table,
            pkColumns: pk,
            column: c.name,
            type: c.type,
            typeName: c.typeName,
            nullable: c.nullable,
            isGenerated: c.isGenerated,
            isIdentity: c.isIdentity,
            readOnly: pk.isEmpty || c.isGenerated || c.isIdentity,
            multiLine:
                c.type == PgType.json ||
                c.type == PgType.jsonb ||
                c.type == PgType.text,
            nullIfBlank: c.nullable,
            enumValues: c.enumValues,
          ),
      ];
      ref.row = row;
      ref.isLoading = false;
      ref.error = row == null
          ? 'Row not found (it may have been deleted).'
          : null;
    } catch (e) {
      if (!mounted) return;
      if (widget.tab.previewRow != ref) return;
      ref.isLoading = false;
      ref.error = classify(e).message;
    }
    AppState.instance.notifyChange();
  }

  /// Apply a cell edit issued from the inspector while previewing a row.
  /// Same flow as [_saveRowCell] but the source-of-truth is the preview
  /// ref rather than a canvas node.
  Future<void> _savePreviewCell(
    LinkedRowRef ref,
    EditPolicy policy,
    Object? newRaw,
  ) async {
    final conn = _conn();
    final row = ref.row;
    if (conn == null || row == null) return;
    final pkValues = <String, Object?>{
      for (final pk in policy.pkColumns) pk: row[pk],
    };
    try {
      final editor = CellEditor(conn);
      final result = await editor.updateCell(
        policy: policy,
        pkValues: pkValues,
        oldValue: row[policy.column],
        newValueRaw: newRaw,
      );
      if (!mounted) return;
      if (widget.tab.previewRow != ref) return;
      if (result.affectedRows == 0) {
        showToast(context, 'Row changed since you loaded it. Reloading.');
        await _loadPreviewRow(ref);
        return;
      }
      ref.row = {...row, policy.column: result.newValue};
      AppState.instance.notifyChange();
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'Update failed: ${classify(e).message}');
    }
  }

  /// Promote the preview row to a real canvas node. Used by the inspector's
  /// FK-navigation buttons so spawning a follow-up node always anchors to a
  /// real source on the canvas, never to a peek.
  LinkedRowNode? _promotePreview() {
    final tab = widget.tab;
    final ref = tab.previewRow;
    if (ref == null) return null;
    final existing = tab.findRow(ref.schema, ref.table, ref.pkValues);
    if (existing != null) {
      tab.selectedNodeId = existing.id;
      tab.previewRow = null;
      AppState.instance.notifyChange();
      return existing;
    }
    final source = tab.selectedRowNode;
    final position = source == null
        ? const Offset(60, 60)
        : _placeNextTo(source);
    final node = LinkedRowNode(
      position: position,
      schema: ref.schema,
      table: ref.table,
      pkColumns: ref.pkColumns,
      pkValues: ref.pkValues,
    );
    node.row = ref.row;
    node.columns = ref.columns;
    node.editPolicies = ref.editPolicies;
    node.error = ref.error;
    tab.nodes.add(node);
    tab.selectedNodeId = node.id;
    tab.previewRow = null;
    AppState.instance.notifyChange();
    return node;
  }

  /// Place a freshly spawned node next to [source]. Vertical bumping
  /// avoids overlapping an existing node at the same column. Keeps a
  /// hand-laid-out canvas readable without doing real auto-layout.
  Offset _placeNextTo(LinkedNode source) {
    final fks = widget.tab.foreignKeys;
    final base = source.position + Offset(source.width + _kHorizontalGap, 0);
    var candidate = base;
    final occupied = <Rect>[
      for (final n in widget.tab.nodes)
        Rect.fromLTWH(
          n.position.dx,
          n.position.dy,
          n.width,
          n is LinkedRowNode
              ? _nodeHeightFor(n, fks)
              : _kHeaderHeight + _kRowHeight,
        ),
    ];
    const fallbackHeight = _kHeaderHeight + 4 * _kRowHeight;
    final fallbackWidth = source.width;
    var safety = 0;
    while (occupied.any(
          (r) => r.overlaps(
            Rect.fromLTWH(
              candidate.dx,
              candidate.dy,
              fallbackWidth,
              fallbackHeight,
            ),
          ),
        ) &&
        safety < 40) {
      candidate += const Offset(0, fallbackHeight + _kVerticalGap);
      safety++;
    }
    return candidate;
  }

  // ---- Row node loading & DML ------------------------------------------

  Future<void> _loadRowNode(LinkedRowNode node) async {
    final conn = _conn();
    if (conn == null) {
      node.error = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    node.isLoading = true;
    node.error = null;
    AppState.instance.notifyChange();
    try {
      final catalog = SchemaCatalog(conn);
      final cols = await catalog.listColumns(node.schema, node.table);
      final pk = await catalog.primaryKey(node.schema, node.table);
      final values = <Object?>[];
      for (final c in pk) {
        final i = node.pkColumns.indexOf(c);
        values.add(i >= 0 ? node.pkValues[i] : null);
      }
      final row = await catalog.loadRowByPk(
        schema: node.schema,
        table: node.table,
        pkColumns: pk,
        pkValues: values,
      );
      if (!mounted) return;
      node.columns = cols;
      node.editPolicies = [
        for (final c in cols)
          EditPolicy(
            schema: node.schema,
            table: node.table,
            pkColumns: pk,
            column: c.name,
            type: c.type,
            typeName: c.typeName,
            nullable: c.nullable,
            isGenerated: c.isGenerated,
            isIdentity: c.isIdentity,
            readOnly: pk.isEmpty || c.isGenerated || c.isIdentity,
            multiLine:
                c.type == PgType.json ||
                c.type == PgType.jsonb ||
                c.type == PgType.text,
            nullIfBlank: c.nullable,
            enumValues: c.enumValues,
          ),
      ];
      node.row = row;
      node.isLoading = false;
      node.error = row == null
          ? 'Row not found (it may have been deleted).'
          : null;
    } catch (e) {
      if (!mounted) return;
      node.isLoading = false;
      node.error = classify(e).message;
    }
    AppState.instance.notifyChange();
    if (node.row != null) _autoExpandRow(node);
  }

  /// Soft cap on the auto-expanded canvas. The auto-expand will still add
  /// nodes up to this many, but stops cascading further. The user can
  /// re-`Explode` to re-layout, or close nodes to reclaim slots.
  static const int _kAutoExpandNodeCap = 30;

  /// Diagram-mode behaviour: when a row node loads, automatically spawn
  /// every adjacent FK relationship (outbound + inbound). Re-uses
  /// [_spawnOutbound] / [_spawnInbound], both of which de-dupe via
  /// [LinkedTab.findRow] / [LinkedTab.findList], so cycles collapse and a
  /// re-visit through a sibling FK just adds the missing edge.
  void _autoExpandRow(LinkedRowNode node) {
    final tab = widget.tab;
    final row = node.row;
    if (row == null) return;
    if (tab.nodes.length >= _kAutoExpandNodeCap) return;

    // Outbound: group FKs by constraint key so composite FKs spawn one
    // child, not one per column.
    final outboundByConstraint = <String, List<ForeignKey>>{};
    for (final fk in tab.foreignKeys) {
      if (fk.fromSchema == node.schema && fk.fromTable == node.table) {
        outboundByConstraint.putIfAbsent(fk.constraintKey, () => []).add(fk);
      }
    }
    for (final group in outboundByConstraint.values) {
      // A composite FK with all-null values has no target row to load.
      final allNull = group.every((g) => row[g.fromColumn] == null);
      if (allNull) continue;
      final lead = group.first;
      _spawnOutbound(
        node,
        lead.fromColumn,
        row[lead.fromColumn],
        group,
      );
    }

    // Inbound: each constraint becomes one list node showing the rows
    // that reference us.
    final inboundByConstraint = <String, List<ForeignKey>>{};
    for (final fk in tab.foreignKeys) {
      if (fk.toSchema == node.schema && fk.toTable == node.table) {
        inboundByConstraint.putIfAbsent(fk.constraintKey, () => []).add(fk);
      }
    }
    for (final group in inboundByConstraint.values) {
      _spawnInbound(node, group, retargetPicker: false);
    }
  }

  Future<void> _saveRowCell(
    LinkedRowNode node,
    EditPolicy policy,
    Object? newRaw,
  ) async {
    final conn = _conn();
    final row = node.row;
    if (conn == null || row == null) return;
    final pkValues = <String, Object?>{
      for (final pk in policy.pkColumns) pk: row[pk],
    };
    try {
      final editor = CellEditor(conn);
      final result = await editor.updateCell(
        policy: policy,
        pkValues: pkValues,
        oldValue: row[policy.column],
        newValueRaw: newRaw,
      );
      if (!mounted) return;
      if (result.affectedRows == 0) {
        showToast(context, 'Row changed since you loaded it. Reloading.');
        await _loadRowNode(node);
        return;
      }
      node.row = {...row, policy.column: result.newValue};
      AppState.instance.notifyChange();
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'Update failed: ${classify(e).message}');
    }
  }

  // ---- Spawning ---------------------------------------------------------

  void _spawnOutbound(
    LinkedRowNode source,
    String fromColumn,
    Object? value,
    List<ForeignKey> group,
  ) {
    if (value == null) return;
    final tab = widget.tab;
    final target = group.first;
    final toPkCols = group.map((g) => g.toColumn).toList();
    final pkValues = <Object?>[];
    for (final g in group) {
      pkValues.add(source.row?[g.fromColumn]);
    }
    final existing = tab.findRow(target.toSchema, target.toTable, pkValues);
    if (existing != null) {
      if (!tab.edges.any(
        (e) =>
            e.fromNodeId == source.id &&
            e.toNodeId == existing.id &&
            e.fromColumn == fromColumn,
      )) {
        tab.edges.add(
          LinkedEdge(
            fromNodeId: source.id,
            toNodeId: existing.id,
            fromColumn: fromColumn,
            toColumn: target.toColumn,
          ),
        );
      }
      AppState.instance.notifyChange();
      return;
    }
    final node = LinkedRowNode(
      position: _placeNextTo(source),
      schema: target.toSchema,
      table: target.toTable,
      pkColumns: toPkCols,
      pkValues: pkValues,
    );
    tab.nodes.add(node);
    tab.edges.add(
      LinkedEdge(
        fromNodeId: source.id,
        toNodeId: node.id,
        fromColumn: fromColumn,
        toColumn: target.toColumn,
      ),
    );
    AppState.instance.notifyChange();
    _loadRowNode(node);
  }

  /// Inbound: fetches the first row that references [source] via this FK
  /// group and spawns it as a row card with an incoming edge. When the user
  /// initiates this from the inspector we re-target the left picker to the
  /// referencing table so they can browse more matches; auto-expand passes
  /// [retargetPicker]=false to avoid the picker flickering through every
  /// inbound table as the cascade runs.
  Future<void> _spawnInbound(
    LinkedRowNode source,
    List<ForeignKey> group, {
    bool retargetPicker = true,
  }) async {
    final tab = widget.tab;
    final row = source.row;
    if (row == null) return;
    final fromSchema = group.first.fromSchema;
    final fromTable = group.first.fromTable;

    if (retargetPicker) {
      tab.pickerSchema = fromSchema;
      tab.pickerTable = fromTable;
    }

    final conn = _conn();
    if (conn == null) return;
    try {
      final catalog = SchemaCatalog(conn);
      final pk = await catalog.primaryKey(fromSchema, fromTable);
      if (pk.isEmpty) return;
      final whereCols = group.map((g) => quoteIdent(g.fromColumn)).toList();
      final params = <Object?>[];
      final placeholders = <String>[];
      for (final g in group) {
        params.add(row[g.toColumn]);
        placeholders.add('\$${params.length}');
      }
      final sql =
          'SELECT ${pk.map(quoteIdent).join(', ')} FROM ${quoteQualified(fromSchema, fromTable)} '
          'WHERE (${whereCols.join(', ')}) = (${placeholders.join(', ')}) LIMIT 1';
      final result = await conn.execute(sql, positional: params);
      if (!mounted || result.rows.isEmpty) return;
      final pkValues = List<Object?>.from(result.rows.first);

      final fromColumn = group.first.fromColumn;
      final toColumn = group.first.toColumn;
      final existing = tab.findRow(fromSchema, fromTable, pkValues);
      if (existing != null) {
        if (!tab.edges.any(
          (e) => e.fromNodeId == existing.id && e.toNodeId == source.id,
        )) {
          tab.edges.add(
            LinkedEdge(
              fromNodeId: existing.id,
              toNodeId: source.id,
              fromColumn: fromColumn,
              toColumn: toColumn,
              incoming: true,
            ),
          );
        }
        AppState.instance.notifyChange();
        return;
      }

      final node = LinkedRowNode(
        position: _placeNextTo(source),
        schema: fromSchema,
        table: fromTable,
        pkColumns: pk,
        pkValues: pkValues,
      );
      tab.nodes.add(node);
      // Edge direction matches data flow: the inbound row points AT us.
      tab.edges.add(
        LinkedEdge(
          fromNodeId: node.id,
          toNodeId: source.id,
          fromColumn: fromColumn,
          toColumn: toColumn,
          incoming: true,
        ),
      );
      AppState.instance.notifyChange();
      _loadRowNode(node);
    } catch (_) {
      // Best-effort — inbound auto-expand failure shouldn't block the
      // user from working with the rest of the canvas.
    }
  }

  // ---- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tab = widget.tab;
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          _Header(
            tab: tab,
            onResetView: () {
              tab.pan = Offset.zero;
              tab.scale = 1.0;
              AppState.instance.notifyChange();
            },
            onExplode: _explode,
            onZoomIn: () {
              tab.scale = (tab.scale * 1.2).clamp(0.25, 3.0);
              AppState.instance.notifyChange();
            },
            onZoomOut: () {
              tab.scale = (tab.scale / 1.2).clamp(0.25, 3.0);
              AppState.instance.notifyChange();
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                if (tab.leftPickerCollapsed)
                  _PanelExpander(
                    tooltip: 'Show seed picker',
                    icon: Icons.chevron_right,
                    onTap: () {
                      tab.leftPickerCollapsed = false;
                      AppState.instance.notifyChange();
                    },
                  )
                else
                  SizedBox(
                    width: 280,
                    child: _RowPickerPanel(
                      connectionId: tab.connectionId,
                      schema: tab.pickerSchema,
                      table: tab.pickerTable,
                      onTapRow: _addRowFromSidebar,
                      onCollapse: () {
                        tab.leftPickerCollapsed = true;
                        AppState.instance.notifyChange();
                      },
                    ),
                  ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: GridWithInspector(
                    grid: _CanvasWithMiddle(
                      tab: tab,
                      canvas: _Canvas(
                        tab: tab,
                        onRowNodeMounted: (node) {
                          if (node.row == null &&
                              !node.isLoading &&
                              node.error == null) {
                            _loadRowNode(node);
                          }
                        },
                        onRowNodeActivate: (node) {
                          // Drill in from the schema-style card — open
                          // the underlying row's table in a Table tab.
                          // The user keeps the Linked view open as
                          // context; the Table tab gives them a flat
                          // grid view of the same data.
                          AppState.instance.openOrFocusTable(
                            connectionId: tab.connectionId,
                            schema: node.schema,
                            table: node.table,
                            estimatedRows: -1,
                          );
                        },
                        onNodeContextMenu: _showNodeContextMenu,
                      ),
                      onTapPreviewRow: _previewRowFromList,
                    ),
                    inspector: _RightInspector(
                      tab: tab,
                      onSave: (policy, raw) {
                        final preview = tab.previewRow;
                        if (preview != null) {
                          return _savePreviewCell(preview, policy, raw);
                        }
                        final selected = tab.selectedRowNode;
                        if (selected == null) return Future.value();
                        return _saveRowCell(selected, policy, raw);
                      },
                      onFollowOutbound: (col, value, group) {
                        if (tab.previewRow != null) {
                          final promoted = _promotePreview();
                          if (promoted == null) return;
                          _spawnOutbound(promoted, col, value, group);
                          return;
                        }
                        final selected = tab.selectedRowNode;
                        if (selected == null) return;
                        _spawnOutbound(selected, col, value, group);
                      },
                      onOpenInbound: (group) {
                        if (tab.previewRow != null) {
                          final promoted = _promotePreview();
                          if (promoted == null) return;
                          _spawnInbound(promoted, group);
                          return;
                        }
                        final selected = tab.selectedRowNode;
                        if (selected == null) return;
                        _spawnInbound(selected, group);
                      },
                      onReload: () {
                        final preview = tab.previewRow;
                        if (preview != null) {
                          _loadPreviewRow(preview);
                          return;
                        }
                        final selected = tab.selectedRowNode;
                        if (selected != null) _loadRowNode(selected);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Layered BFS layout. Roots (nodes with no incoming edge) go on the
  /// leftmost column; each child is placed in the next column down-right
  /// of the parent, fanning vertically to avoid overlap.
  void _explode() {
    final tab = widget.tab;
    if (tab.nodes.isEmpty) return;
    _applyExplodeLayout(tab);
    tab.pan = Offset.zero;
    tab.scale = 1.0;
    AppState.instance.notifyChange();
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  final LinkedTab tab;
  final VoidCallback onResetView;
  final VoidCallback onExplode;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  const _Header({
    required this.tab,
    required this.onResetView,
    required this.onExplode,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  @override
  Widget build(BuildContext context) {
    final percent = (tab.scale * 100).round();
    final rowCount = tab.nodes.whereType<LinkedRowNode>().length;
    return PanelHeader(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      titleIcon: Icons.hub_outlined,
      title: 'Linked view',
      subtitle:
          tab.fksError ??
          (tab.fksLoaded ? '$rowCount rows on canvas' : 'loading FKs…'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: rowCount == 0 ? null : onExplode,
            icon: const Icon(Icons.scatter_plot_outlined, size: 16),
            label: const Text('Explode'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
          IconButton(
            tooltip: 'Zoom out',
            icon: const Icon(Icons.remove, size: 18),
            onPressed: onZoomOut,
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$percent%',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            icon: const Icon(Icons.add, size: 18),
            onPressed: onZoomIn,
          ),
          IconButton(
            tooltip: 'Reset view',
            icon: const Icon(Icons.center_focus_strong, size: 18),
            onPressed: onResetView,
          ),
        ],
      ),
    );
  }
}

/// Right-side property inspector for the selected row node. Renders the
/// same [PropertyInspector] the table view uses, so the look and FK
/// affordances match. Visibility is controlled by the global
/// [AppState.propertyInspectorCollapsed] toggle.
class _RightInspector extends StatelessWidget {
  final LinkedTab tab;
  final Future<void> Function(EditPolicy policy, Object? newRaw) onSave;
  final void Function(String fromColumn, Object? value, List<ForeignKey> group)
  onFollowOutbound;
  final void Function(List<ForeignKey> group) onOpenInbound;
  final VoidCallback onReload;
  const _RightInspector({
    required this.tab,
    required this.onSave,
    required this.onFollowOutbound,
    required this.onOpenInbound,
    required this.onReload,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = tab.selectedRowNode;
    final preview = tab.previewRow;
    final hasPreview = preview != null;
    // Source-of-truth for what the inspector renders: preview wins when
    // set; otherwise fall back to the selected node.
    final isLoading = hasPreview ? preview.isLoading : false;
    final error = hasPreview ? preview.error : selected?.error;
    final rowMap = hasPreview ? preview.row : selected?.row;
    final schema = hasPreview ? preview.schema : selected?.schema;
    final table = hasPreview ? preview.table : selected?.table;
    final columns = hasPreview
        ? preview.columns
        : (selected?.columns ?? const []);
    final editPolicies = hasPreview
        ? preview.editPolicies
        : (selected?.editPolicies ?? const []);
    final pkColumns = hasPreview
        ? preview.pkColumns
        : (selected?.pkColumns ?? const []);

    final title = table == null
        ? 'Row inspector (no selection)'
        : hasPreview
        ? 'Preview — $table'
        : 'Row inspector — $table';

    Widget body;
    if (table == null) {
      body = const EmptyState(
        icon: Icons.article_outlined,
        iconSize: 36,
        message: 'Tap a node on the canvas to view its row here.',
      );
    } else if (error != null) {
      body = ErrorView(message: error, onRetry: onReload);
    } else if (rowMap == null || isLoading) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else {
      body = PropertyInspector(
        schema: schema!,
        table: table,
        columns: columns,
        row: rowMap,
        editPolicies: editPolicies,
        pkColumns: pkColumns,
        foreignKeys: tab.foreignKeys,
        connectionId: tab.connectionId,
        onSave: onSave,
        onFollowOutbound: onFollowOutbound,
        onOpenInbound: onOpenInbound,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: AppPanel(
        title: title,
        titleIcon: hasPreview
            ? Icons.visibility_outlined
            : Icons.article_outlined,
        trailing: IconButton(
          tooltip: 'Hide inspector',
          icon: const Icon(Icons.close, size: 14),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(2),
          constraints: const BoxConstraints(),
          onPressed: AppState.instance.togglePropertyInspector,
        ),
        child: body,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Canvas + middle row-list panel
// ---------------------------------------------------------------------------

/// Wraps the canvas with the resizable middle row-list panel. The middle
/// panel shows all rows of the currently-selected node's table; tapping a
/// row pushes it to the inspector preview without spawning a node. Hidden
/// entirely when no node is selected so the canvas keeps full width.
class _CanvasWithMiddle extends StatelessWidget {
  final LinkedTab tab;
  final Widget canvas;
  final void Function({
    required String schema,
    required String table,
    required List<String> pkCols,
    required List<Object?> pkValues,
  })
  onTapPreviewRow;
  const _CanvasWithMiddle({
    required this.tab,
    required this.canvas,
    required this.onTapPreviewRow,
  });

  @override
  Widget build(BuildContext context) {
    final selected = tab.selectedRowNode;
    if (selected == null) return canvas;
    final preview = tab.previewRow;
    final selectedPk =
        preview != null &&
            preview.schema == selected.schema &&
            preview.table == selected.table
        ? preview.pkValues
        : selected.pkValues;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: canvas),
        if (tab.middlePanelCollapsed)
          _PanelExpander(
            tooltip: 'Show preview picker',
            icon: Icons.chevron_left,
            onTap: () {
              tab.middlePanelCollapsed = false;
              AppState.instance.notifyChange();
            },
          )
        else
          Resizable(
            width: tab.middlePanelWidth,
            minWidth: 220,
            maxWidth: 600,
            side: ResizeSide.left,
            onResized: (w) {
              tab.middlePanelWidth = w;
              AppState.instance.notifyChange();
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: _RowPickerPanel(
                connectionId: tab.connectionId,
                schema: selected.schema,
                table: selected.table,
                onTapRow: onTapPreviewRow,
                trailingIcon: Icons.visibility_outlined,
                selectedPkValues: selectedPk,
                restrictPkCols: selected.pkColumns,
                restrictPkValues: selected.pkValues,
                emptyHint: 'No rows.',
                tableHint: 'No table selected.',
                onCollapse: () {
                  tab.middlePanelCollapsed = true;
                  AppState.instance.notifyChange();
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// Thin vertical strip shown in place of a collapsed panel. Tapping the
/// chevron icon expands the panel via the supplied [onTap].
class _PanelExpander extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _PanelExpander({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 22,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border(
          left: BorderSide(color: theme.dividerColor),
          right: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          child: Center(child: Icon(icon, size: 16, color: theme.hintColor)),
        ),
      ),
    );
  }
}

/// Pure layout helper for the "Explode" button. Walks the FK graph,
/// assigns each node a (column, row) slot, and writes the resulting
/// canvas-space positions back to the nodes in place. Does not touch
/// pan/scale or notify AppState — the caller does both around it.
///
/// Algorithm: BFS from "root" nodes (no incoming edge) assigning depth
/// = column. Each column's stride uses the widest node in that column
/// so wider cards never visually crash into the next column. Within a
/// column, nodes stack vertically with [_kVerticalGap] between them.
void _applyExplodeLayout(LinkedTab tab) {
  final byId = {for (final n in tab.nodes) n.id: n};
  final incoming = <String, int>{for (final n in tab.nodes) n.id: 0};
  final outgoing = <String, List<String>>{
    for (final n in tab.nodes) n.id: <String>[],
  };
  for (final e in tab.edges) {
    if (!byId.containsKey(e.fromNodeId) || !byId.containsKey(e.toNodeId)) {
      continue;
    }
    incoming[e.toNodeId] = (incoming[e.toNodeId] ?? 0) + 1;
    outgoing[e.fromNodeId]!.add(e.toNodeId);
  }

  // Roots = nodes with no incoming edge; if every node has one (cycle),
  // pick the first node as a fallback root so layout still completes.
  final roots = [
    for (final n in tab.nodes)
      if ((incoming[n.id] ?? 0) == 0) n.id,
  ];
  if (roots.isEmpty) roots.add(tab.nodes.first.id);

  final depth = <String, int>{for (final r in roots) r: 0};
  final queue = <String>[...roots];
  while (queue.isNotEmpty) {
    final id = queue.removeAt(0);
    final d = depth[id]!;
    for (final child in outgoing[id]!) {
      // First-write-wins so a long path doesn't push a node deeper than
      // needed (DAG-ish layouts read better that way).
      if (depth.containsKey(child)) continue;
      depth[child] = d + 1;
      queue.add(child);
    }
  }
  // Orphans (unreachable from any root after the fallback) — append at
  // depth 0 so they still show up.
  for (final n in tab.nodes) {
    depth.putIfAbsent(n.id, () => 0);
  }

  // Bucket by depth, place column-by-column.
  final columns = <int, List<String>>{};
  for (final entry in depth.entries) {
    columns.putIfAbsent(entry.value, () => []).add(entry.key);
  }
  const margin = 40.0;
  final fks = tab.foreignKeys;
  final sortedDepths = columns.keys.toList()..sort();
  // Column stride per depth uses the widest node at that depth so wider
  // cards don't visually crash into the column to their right.
  final colWidth = <int, double>{
    for (final d in sortedDepths)
      d: columns[d]!
          .map((id) => byId[id]!.width)
          .fold<double>(_kDefaultNodeWidth, (a, b) => a > b ? a : b),
  };
  final colStart = <int, double>{};
  double cursor = margin;
  for (final d in sortedDepths) {
    colStart[d] = cursor;
    cursor += colWidth[d]! + _kHorizontalGap;
  }
  for (final d in sortedDepths) {
    final ids = columns[d]!;
    var y = margin;
    for (final id in ids) {
      final n = byId[id]!;
      n.position = Offset(colStart[d]!, y);
      final h = n is LinkedRowNode
          ? _nodeHeightFor(n, fks)
          : _kHeaderHeight + _kRowHeight;
      y += h + _kVerticalGap;
    }
  }
}
