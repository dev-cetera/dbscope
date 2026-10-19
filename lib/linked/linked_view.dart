library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:schema_viewer/schema_viewer.dart';
import 'package:widgets/widgets.dart';

import '../catalog/schema_catalog.dart';
import '../connection/registry.dart';
import '../db/dml.dart';
import '../db/edit_policies.dart';
import '../db/edit_policy.dart';
import '../db/executor.dart';
import '../grid/data_grid.dart';
import '../inspector/grid_with_inspector.dart';
import '../inspector/property_inspector.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../meta/value_format.dart';
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
const _kListPageSize = 200;

/// Longest cell value shown on a node card before it is cut off with an
/// ellipsis. Also used when measuring how wide a card must be.
const _kMaxValueDisplayLength = 32;

/// Rendered height for a row node — header + optional seed-subtitle +
/// one row per visible column. Cards render in compact mode (PK / FK /
/// ref-target rows only), so [_compactColumnsFor] is what drives both
/// height and edge-anchor math.
double _nodeHeightFor(LinkedRowNode node, List<ForeignKey> allForeignKeys) {
  final hasSubtitle = _nodeSubtitle(node) != null;
  final columnCount = _compactColumnsFor(node, allForeignKeys).length;
  return schemaNodeHeight(columnCount, hasSubtitle: hasSubtitle);
}

/// Y position (canvas-space, relative to a node's top) of the centre of
/// the row holding [columnName]. Used by the edge painter to anchor
/// endpoints to the exact field row.
double? _columnAnchorYFor(
  LinkedRowNode node,
  List<ForeignKey> allForeignKeys,
  String? columnName,
) {
  if (columnName == null) return null;
  final hasSubtitle = _nodeSubtitle(node) != null;
  final columns = _compactColumnsFor(node, allForeignKeys);
  final index = columns.indexOf(columnName);
  if (index < 0) return null;
  final headerOffset = _kHeaderHeight + (hasSubtitle ? _kSubtitleHeight : 0);
  return headerOffset + index * _kRowHeight + _kRowHeight / 2;
}

/// Per-table colour used in the sidebar's relationship gutter. Linked-view
/// nodes outline themselves with this and edges use the destination node's
/// colour so visual identity is consistent between the two views.
Color _colorForNode(LinkedNode node) {
  if (node is LinkedRowNode) {
    return colorForTable('${node.schema}.${node.table}');
  }
  if (node is LinkedListNode) {
    return colorForTable('${node.schema}.${node.table}');
  }
  return Colors.grey;
}

/// Compute a width that fits the widest row in [node]'s body without
/// truncating. Uses TextPainter so fonts + sizes match what actually
/// renders. Clamped to a sane min/max so a runaway-long column name
/// can't push the node off-screen — the user can drag the right edge
/// to grow it further.
double _autoWidthFor(LinkedRowNode node, List<ForeignKey> foreignKeys) {
  const headerStyle = TextStyle(fontSize: 13.0, fontWeight: FontWeight.w700);
  const subtitleStyle = TextStyle(fontSize: 11, fontFamily: 'Menlo');
  const nameStyle = TextStyle(fontSize: 12.0);
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
  var widest = measure(node.table, headerStyle) + (node.isSeed ? 18 : 0);
  // Two 20-px header buttons (open + compact) live in the SchemaCard
  // header; reserve their width so the title doesn't truncate.
  widest += 50;

  // Subtitle: the row label, or the seed's (pk=val ...).
  final subtitle = _nodeSubtitle(node);
  if (subtitle != null) {
    final sw = measure(subtitle, subtitleStyle);
    if (sw > widest) widest = sw;
  }

  // Body rows: name on the left, type-or-value on the right.
  final columns = node.columns.isNotEmpty
      ? [for (final c in node.columns) (name: c.name, type: c.typeName)]
      : [
          for (final c in node.bodyColumnOrder(foreignKeys)) (name: c, type: ''),
        ];
  for (final column in columns) {
    final right = node.row != null
        ? (() {
            final value = node.row?[column.name];
            if (value == null) return 'NULL';
            final text = value.toString();
            return text.length > _kMaxValueDisplayLength
                ? '${text.substring(0, _kMaxValueDisplayLength)}…'
                : text;
          })()
        : column.type;
    // 8px gap between left + right, plus prefix glyph ("* "/"+ ") width.
    final width = measure(column.name, nameStyle) + 12 + measure(right, typeStyle) + 8;
    if (width > widest) widest = width;
  }

  // Card padding (10 + 10) and a little breathing room.
  final raw = widest + 22;
  return raw.clamp(_kMinNodeWidth, _kMaxAutoWidth);
}

class LinkedTabView extends StatefulWidget {
  const LinkedTabView({super.key, required this.tab});
  final LinkedTab tab;

  @override
  State<LinkedTabView> createState() => _LinkedTabViewState();
}

class _LinkedTabViewState extends State<LinkedTabView> {
  /// The metadata row label for [row], or null without a template.
  String? _metaRowLabel(
    String schema,
    String table,
    Map<String, Object?>? row,
  ) {
    if (row == null) return null;
    final template = MetadataCache.instance
        .snapshotFor(widget.tab.connectionId)
        ?.index
        .displayTable(schema, table)
        .rowLabel;
    if (template == null) return null;
    final label = renderRowLabel(template, row).trim();
    return label.isEmpty ? null : label;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadFKs());
      _bootstrapSeedIfNeeded();
    });
  }

  DbExecutor? _executor() => ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _loadFKs() async {
    final tab = widget.tab;
    if (tab.fksLoaded) return;
    final executor = _executor();
    if (executor == null) {
      tab.fksError = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    try {
      final foreignKeys = await SchemaCatalog(executor).listForeignKeys();
      tab.foreignKeys = foreignKeys;
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
    var position = const Offset(60.0, 60.0);
    if (tab.nodes.isNotEmpty) {
      final maxRight = tab.nodes
          .map((otherNode) => otherNode.position.dx)
          .reduce((a, b) => a > b ? a : b);
      // Use the right-most node's width to space the new one.
      final rightMost = tab.nodes.reduce(
        (a, b) => a.position.dx > b.position.dx ? a : b,
      );
      position = Offset(maxRight + rightMost.width + _kHorizontalGap, 60.0);
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
    unawaited(_loadRowNode(node));
  }

  /// Drops the connected component containing [node] from the canvas.
  /// Triggered from the per-node right-click context menu — picking any
  /// node in a chain removes the whole chain.
  void _removeChain(LinkedNode node) {
    widget.tab.removeChain(node.id);
    AppState.instance.notifyChange();
  }

  Future<void> _showNodeContextMenu(
    LinkedNode node,
    Offset globalPosition,
  ) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx + 1,
        globalPosition.dy + 1,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'remove_chain',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.scatter_plot_outlined, size: 16.0),
              SizedBox(width: 8.0),
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
    unawaited(_loadPreviewRow(ref));
  }

  Future<void> _loadPreviewRow(LinkedRowRef ref) async {
    final executor = _executor();
    if (executor == null) {
      ref.error = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    ref.isLoading = true;
    ref.error = null;
    AppState.instance.notifyChange();
    try {
      final catalog = SchemaCatalog(executor);
      final columns = await catalog.listColumns(ref.schema, ref.table);
      final primaryKey = await catalog.primaryKey(ref.schema, ref.table);
      final values = <Object?>[];
      for (final column in primaryKey) {
        final i = ref.pkColumns.indexOf(column);
        values.add(i >= 0 ? ref.pkValues[i] : null);
      }
      final row = await catalog.loadRowByPk(
        schema: ref.schema,
        table: ref.table,
        pkColumns: primaryKey,
        pkValues: values,
      );
      if (!mounted) return;
      // The preview may have been replaced or cleared while we awaited —
      // discard this load so we don't paint stale data over a newer one.
      if (widget.tab.previewRow != ref) return;
      ref.columns = columns;
      ref.editPolicies = buildEditPolicies(
        conn: executor,
        schema: ref.schema,
        table: ref.table,
        columns: columns,
        pkColumns: primaryKey,
      );
      ref.row = row;
      ref.isLoading = false;
      ref.error = row == null ? 'Row not found (it may have been deleted).' : null;
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
    final executor = _executor();
    final row = ref.row;
    if (executor == null || row == null) return;
    final pkValues = <String, Object?>{
      for (final primaryKey in policy.pkColumns) primaryKey: row[primaryKey],
    };
    try {
      final editor = CellEditor(executor);
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
    final position = source == null ? const Offset(60.0, 60.0) : _placeNextTo(source);
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

  /// Upper bound on how many times [_placeNextTo] bumps the candidate slot
  /// down, so a crowded canvas can never loop forever.
  static const _kMaxPlacementAttempts = 40;

  /// Place a freshly spawned node next to [source]. Vertical bumping
  /// avoids overlapping an existing node at the same column. Keeps a
  /// hand-laid-out canvas readable without doing real auto-layout.
  Offset _placeNextTo(LinkedNode source) {
    final foreignKeys = widget.tab.foreignKeys;
    final base = source.position + Offset(source.width + _kHorizontalGap, 0.0);
    var candidate = base;
    final occupied = <Rect>[
      for (final node in widget.tab.nodes)
        Rect.fromLTWH(
          node.position.dx,
          node.position.dy,
          node.width,
          node is LinkedRowNode ? _nodeHeightFor(node, foreignKeys) : _kHeaderHeight + _kRowHeight,
        ),
    ];
    const fallbackHeight = _kHeaderHeight + 4 * _kRowHeight;
    final fallbackWidth = source.width;
    var safety = 0;
    while (occupied.any(
          (rect) => rect.overlaps(
            Rect.fromLTWH(
              candidate.dx,
              candidate.dy,
              fallbackWidth,
              fallbackHeight,
            ),
          ),
        ) &&
        safety < _kMaxPlacementAttempts) {
      candidate += const Offset(0.0, fallbackHeight + _kVerticalGap);
      safety++;
    }
    return candidate;
  }

  // ---- Row node loading & DML ------------------------------------------

  Future<void> _loadRowNode(LinkedRowNode node) async {
    final executor = _executor();
    if (executor == null) {
      node.error = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    node.isLoading = true;
    node.error = null;
    AppState.instance.notifyChange();
    try {
      final catalog = SchemaCatalog(executor);
      final columns = await catalog.listColumns(node.schema, node.table);
      final primaryKey = await catalog.primaryKey(node.schema, node.table);
      final values = <Object?>[];
      for (final column in primaryKey) {
        final i = node.pkColumns.indexOf(column);
        values.add(i >= 0 ? node.pkValues[i] : null);
      }
      final row = await catalog.loadRowByPk(
        schema: node.schema,
        table: node.table,
        pkColumns: primaryKey,
        pkValues: values,
      );
      if (!mounted) return;
      node.columns = columns;
      node.editPolicies = buildEditPolicies(
        conn: executor,
        schema: node.schema,
        table: node.table,
        columns: columns,
        pkColumns: primaryKey,
      );
      node.row = row;
      node.rowLabel = _metaRowLabel(node.schema, node.table, row);
      node.isLoading = false;
      node.error = row == null ? 'Row not found (it may have been deleted).' : null;
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
  static const _kAutoExpandNodeCap = 30;

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
    for (final foreignKey in tab.foreignKeys) {
      if (foreignKey.fromSchema == node.schema && foreignKey.fromTable == node.table) {
        outboundByConstraint.putIfAbsent(foreignKey.constraintKey, () => []).add(foreignKey);
      }
    }
    for (final group in outboundByConstraint.values) {
      // A composite FK with all-null values has no target row to load.
      final allNull = group.every((member) => row[member.fromColumn] == null);
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
    for (final foreignKey in tab.foreignKeys) {
      if (foreignKey.toSchema == node.schema && foreignKey.toTable == node.table) {
        inboundByConstraint.putIfAbsent(foreignKey.constraintKey, () => []).add(foreignKey);
      }
    }
    for (final group in inboundByConstraint.values) {
      unawaited(_spawnInbound(node, group, retargetPicker: false));
    }
  }

  Future<void> _saveRowCell(
    LinkedRowNode node,
    EditPolicy policy,
    Object? newRaw,
  ) async {
    final executor = _executor();
    final row = node.row;
    if (executor == null || row == null) return;
    final pkValues = <String, Object?>{
      for (final primaryKey in policy.pkColumns) primaryKey: row[primaryKey],
    };
    try {
      final editor = CellEditor(executor);
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
    final toPrimaryKeyColumns = group.map((member) => member.toColumn).toList();
    final pkValues = <Object?>[];
    for (final member in group) {
      pkValues.add(source.row?[member.fromColumn]);
    }
    final existing = tab.findRow(target.toSchema, target.toTable, pkValues);
    if (existing != null) {
      if (!tab.edges.any(
        (e) => e.fromNodeId == source.id && e.toNodeId == existing.id && e.fromColumn == fromColumn,
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
      pkColumns: toPrimaryKeyColumns,
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
    unawaited(_loadRowNode(node));
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

    final executor = _executor();
    if (executor == null) return;
    try {
      final catalog = SchemaCatalog(executor);
      final primaryKey = await catalog.primaryKey(fromSchema, fromTable);
      if (primaryKey.isEmpty) return;
      final whereColumns = group.map((member) => quoteIdent(member.fromColumn)).toList();
      final params = <Object?>[];
      final placeholders = <String>[];
      for (final member in group) {
        params.add(row[member.toColumn]);
        placeholders.add('\$${params.length}');
      }
      final sql =
          'SELECT ${primaryKey.map(quoteIdent).join(', ')} FROM ${quoteQualified(fromSchema, fromTable)} '
          'WHERE (${whereColumns.join(', ')}) = (${placeholders.join(', ')}) LIMIT 1';
      final result = await executor.execute(sql, positional: params);
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
        pkColumns: primaryKey,
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
      unawaited(_loadRowNode(node));
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
    return ColoredBox(
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
          const Divider(height: 1.0),
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
                    width: 280.0,
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
                const VerticalDivider(width: 1.0),
                Expanded(
                  child: GridWithInspector(
                    grid: _CanvasWithMiddle(
                      tab: tab,
                      canvas: _Canvas(
                        tab: tab,
                        onRowNodeMounted: (node) {
                          if (node.row == null && !node.isLoading && node.error == null) {
                            unawaited(_loadRowNode(node));
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
                      onFollowOutbound: (column, value, group) {
                        if (tab.previewRow != null) {
                          final promoted = _promotePreview();
                          if (promoted == null) return;
                          _spawnOutbound(promoted, column, value, group);
                          return;
                        }
                        final selected = tab.selectedRowNode;
                        if (selected == null) return;
                        _spawnOutbound(selected, column, value, group);
                      },
                      onOpenInbound: (group) {
                        if (tab.previewRow != null) {
                          final promoted = _promotePreview();
                          if (promoted == null) return;
                          unawaited(_spawnInbound(promoted, group));
                          return;
                        }
                        final selected = tab.selectedRowNode;
                        if (selected == null) return;
                        unawaited(_spawnInbound(selected, group));
                      },
                      onReload: () {
                        final preview = tab.previewRow;
                        if (preview != null) {
                          unawaited(_loadPreviewRow(preview));
                          return;
                        }
                        final selected = tab.selectedRowNode;
                        if (selected != null) unawaited(_loadRowNode(selected));
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
  const _Header({
    required this.tab,
    required this.onResetView,
    required this.onExplode,
    required this.onZoomIn,
    required this.onZoomOut,
  });
  final LinkedTab tab;
  final VoidCallback onResetView;
  final VoidCallback onExplode;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final percent = (tab.scale * 100).round();
    final rowCount = tab.nodes.whereType<LinkedRowNode>().length;
    return PanelHeader(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      titleIcon: Icons.hub_outlined,
      title: 'Linked view',
      subtitle: tab.fksError ?? (tab.fksLoaded ? '$rowCount rows on canvas' : 'loading FKs…'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: rowCount == 0 ? null : onExplode,
            icon: const Icon(Icons.scatter_plot_outlined, size: 16.0),
            label: const Text('Explode'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
          IconButton(
            tooltip: 'Zoom out',
            icon: const Icon(Icons.remove, size: 18.0),
            onPressed: onZoomOut,
          ),
          SizedBox(
            width: 44.0,
            child: Text(
              '$percent%',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            icon: const Icon(Icons.add, size: 18.0),
            onPressed: onZoomIn,
          ),
          IconButton(
            tooltip: 'Reset view',
            icon: const Icon(Icons.center_focus_strong, size: 18.0),
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
  const _RightInspector({
    required this.tab,
    required this.onSave,
    required this.onFollowOutbound,
    required this.onOpenInbound,
    required this.onReload,
  });
  final LinkedTab tab;
  final Future<void> Function(EditPolicy policy, Object? newRaw) onSave;
  final void Function(String fromColumn, Object? value, List<ForeignKey> group) onFollowOutbound;
  final void Function(List<ForeignKey> group) onOpenInbound;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = tab.selectedRowNode;
    final preview = tab.previewRow;
    final hasPreview = preview != null;
    // Source-of-truth for what the inspector renders: preview wins when
    // set; otherwise fall back to the selected node.
    final isLoading = hasPreview && preview.isLoading;
    final error = hasPreview ? preview.error : selected?.error;
    final rowMap = hasPreview ? preview.row : selected?.row;
    final schema = hasPreview ? preview.schema : selected?.schema;
    final table = hasPreview ? preview.table : selected?.table;
    final columns = hasPreview ? preview.columns : (selected?.columns ?? const []);
    final editPolicies = hasPreview ? preview.editPolicies : (selected?.editPolicies ?? const []);
    final pkColumns = hasPreview ? preview.pkColumns : (selected?.pkColumns ?? const []);

    final title = table == null
        ? 'Row inspector (no selection)'
        : hasPreview
        ? 'Preview — $table'
        : 'Row inspector — $table';

    Widget body;
    if (table == null) {
      body = const EmptyState(
        icon: Icons.article_outlined,
        iconSize: 36.0,
        message: 'Tap a node on the canvas to view its row here.',
      );
    } else if (error != null) {
      body = ErrorView(message: error, onRetry: onReload);
    } else if (rowMap == null || isLoading) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: SizedBox(
            width: 20.0,
            height: 20.0,
            child: CircularProgressIndicator(strokeWidth: 2.0),
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
        titleIcon: hasPreview ? Icons.visibility_outlined : Icons.article_outlined,
        trailing: IconButton(
          tooltip: 'Hide inspector',
          icon: const Icon(Icons.close, size: 14.0),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(2.0),
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
  const _CanvasWithMiddle({
    required this.tab,
    required this.canvas,
    required this.onTapPreviewRow,
  });
  final LinkedTab tab;
  final Widget canvas;
  final void Function({
    required String schema,
    required String table,
    required List<String> pkCols,
    required List<Object?> pkValues,
  })
  onTapPreviewRow;

  @override
  Widget build(BuildContext context) {
    final selected = tab.selectedRowNode;
    // The Row and the Expanded are unconditional: returning `canvas`
    // bare when nothing is selected would swap this slot's widget type
    // as the panel comes and goes, unmounting the canvas and discarding
    // its State — see the note on `_mainAreaKey` in app.dart.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: canvas),
        if (selected != null)
          _MiddlePane(
            tab: tab,
            selected: selected,
            onTapPreviewRow: onTapPreviewRow,
          ),
      ],
    );
  }
}

/// The middle row-list panel: every row of [selected]'s table, tapping
/// one pushes it to the inspector preview. Collapses to a thin
/// [_PanelExpander] strip.
class _MiddlePane extends StatelessWidget {
  const _MiddlePane({
    required this.tab,
    required this.selected,
    required this.onTapPreviewRow,
  });
  final LinkedTab tab;
  final LinkedRowNode selected;
  final void Function({
    required String schema,
    required String table,
    required List<String> pkCols,
    required List<Object?> pkValues,
  })
  onTapPreviewRow;

  @override
  Widget build(BuildContext context) {
    if (tab.middlePanelCollapsed) {
      return _PanelExpander(
        tooltip: 'Show preview picker',
        icon: Icons.chevron_left,
        onTap: () {
          tab.middlePanelCollapsed = false;
          AppState.instance.notifyChange();
        },
      );
    }
    final preview = tab.previewRow;
    final selectedPrimaryKey =
        preview != null && preview.schema == selected.schema && preview.table == selected.table
        ? preview.pkValues
        : selected.pkValues;
    return Resizable(
      width: tab.middlePanelWidth,
      minWidth: 220.0,
      maxWidth: 600.0,
      side: ResizeSide.left,
      onResized: (width) {
        tab.middlePanelWidth = width;
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
          selectedPkValues: selectedPrimaryKey,
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
    );
  }
}

/// Thin vertical strip shown in place of a collapsed panel. Tapping the
/// chevron icon expands the panel via the supplied [onTap].
class _PanelExpander extends StatelessWidget {
  const _PanelExpander({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 22.0,
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
          child: Center(child: Icon(icon, size: 16.0, color: theme.hintColor)),
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
  final byId = {for (final node in tab.nodes) node.id: node};
  final incoming = <String, int>{for (final node in tab.nodes) node.id: 0};
  final outgoing = <String, List<String>>{
    for (final node in tab.nodes) node.id: <String>[],
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
    for (final node in tab.nodes)
      if ((incoming[node.id] ?? 0) == 0) node.id,
  ];
  if (roots.isEmpty) roots.add(tab.nodes.first.id);

  final depth = <String, int>{for (final r in roots) r: 0};
  final queue = <String>[...roots];
  while (queue.isNotEmpty) {
    final id = queue.removeAt(0);
    final parentDepth = depth[id]!;
    for (final child in outgoing[id]!) {
      // First-write-wins so a long path doesn't push a node deeper than
      // needed (DAG-ish layouts read better that way).
      if (depth.containsKey(child)) continue;
      depth[child] = parentDepth + 1;
      queue.add(child);
    }
  }
  // Orphans (unreachable from any root after the fallback) — append at
  // depth 0 so they still show up.
  for (final node in tab.nodes) {
    depth.putIfAbsent(node.id, () => 0);
  }

  // Bucket by depth, place column-by-column.
  final columns = <int, List<String>>{};
  for (final entry in depth.entries) {
    columns.putIfAbsent(entry.value, () => []).add(entry.key);
  }
  const margin = 40.0;
  final foreignKeys = tab.foreignKeys;
  final sortedDepths = columns.keys.toList()..sort();
  // Column stride per depth uses the widest node at that depth so wider
  // cards don't visually crash into the column to their right.
  final colWidth = <int, double>{
    for (final columnDepth in sortedDepths)
      columnDepth: columns[columnDepth]!
          .map((id) => byId[id]!.width)
          .fold<double>(_kDefaultNodeWidth, (a, b) => a > b ? a : b),
  };
  final colStart = <int, double>{};
  var cursor = margin;
  for (final columnDepth in sortedDepths) {
    colStart[columnDepth] = cursor;
    cursor += colWidth[columnDepth]! + _kHorizontalGap;
  }
  for (final columnDepth in sortedDepths) {
    final ids = columns[columnDepth]!;
    var y = margin;
    for (final id in ids) {
      final node = byId[id]!;
      node.position = Offset(colStart[columnDepth]!, y);
      final height = node is LinkedRowNode
          ? _nodeHeightFor(node, foreignKeys)
          : _kHeaderHeight + _kRowHeight;
      y += height + _kVerticalGap;
    }
  }
}
