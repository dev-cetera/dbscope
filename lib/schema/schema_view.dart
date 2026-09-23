import 'package:flutter/material.dart';
import 'package:schema_viewer/schema_viewer.dart';
import 'package:widgets/widgets.dart';

import '../catalog/schema_catalog.dart';
import '../connection/registry.dart';
import '../db/executor.dart';
import '../shell/app_state.dart';
import 'schema_tab.dart';

/// View widget for [SchemaTab]. Loads catalog data for the active
/// connection (tables, columns, FKs), maps it onto [SchemaNodeData] /
/// [SchemaEdgeData], runs the dagre-like layout, and hands everything
/// off to the shared [SchemaCanvas] from package:schema_viewer.
class SchemaTabView extends StatefulWidget {
  final SchemaTab tab;
  const SchemaTabView({super.key, required this.tab});

  @override
  State<SchemaTabView> createState() => _SchemaTabViewState();
}

class _SchemaTabViewState extends State<SchemaTabView> {
  late final SchemaCanvasController _canvasCtrl = SchemaCanvasController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.tab.isLoaded) _loadSchema();
    });
  }

  DbExecutor? _conn() =>
      ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _loadSchema({bool force = false}) async {
    final tab = widget.tab;
    if (tab.isLoading) return;
    tab.isLoading = true;
    tab.error = null;
    AppState.instance.notifyChange();
    try {
      final conn = _conn();
      if (conn == null) {
        tab.error = 'No connection.';
        return;
      }
      final cat = SchemaCatalog(conn);
      final schemas = await cat.listSchemas();
      final userSchemas = schemas
          .where((s) => !s.isSystem)
          .map((s) => s.name)
          .toList();
      // Gather diagrammable tables across every user schema first, so we
      // can spot table names that collide across schemas. A table living
      // in more than one schema (e.g. `public.groups` and `auth.groups`)
      // would otherwise render as two identical-looking "groups" cards,
      // since the card header shows only the bare table name.
      final diagramTables = <(String schema, TableInfo table)>[];
      for (final schemaName in userSchemas) {
        final tables = await cat.listTables(schemaName);
        for (final t in tables) {
          if (t.kind != 'BASE TABLE' && t.kind != 'VIEW') continue;
          diagramTables.add((schemaName, t));
        }
      }
      final nameCounts = <String, int>{};
      for (final (_, t) in diagramTables) {
        nameCounts[t.name] = (nameCounts[t.name] ?? 0) + 1;
      }

      final nodes = <SchemaNodeData>[];
      for (final (schemaName, t) in diagramTables) {
        final cols = force
            ? await cat.listColumns(schemaName, t.name)
            : (tab.cachedColumns(schemaName, t.name) ??
                  await cat.listColumns(schemaName, t.name));
        tab.setCachedColumns(schemaName, t.name, cols);
        final pkCols = (await cat.primaryKey(schemaName, t.name)).toSet();
        nodes.add(
          SchemaNodeData(
            id: '$schemaName.${t.name}',
            schema: schemaName,
            tableName: t.name,
            // Disambiguate cards when the same table name exists in more
            // than one schema; single-schema names stay uncluttered.
            subtitle: (nameCounts[t.name] ?? 0) > 1 ? schemaName : null,
            fields: [
              for (final c in cols)
                SchemaFieldSpec(
                  name: c.name,
                  typeLabel: c.typeName,
                  pk: pkCols.contains(c.name),
                ),
            ],
          ),
        );
      }

      final fks = await cat.listForeignKeys();
      final byId = {for (final n in nodes) n.id: n};
      final edges = <SchemaEdgeData>[];
      var edgeId = 0;
      for (final fk in fks) {
        final srcId = '${fk.fromSchema}.${fk.fromTable}';
        final tgtId = '${fk.toSchema}.${fk.toTable}';
        final srcNode = byId[srcId];
        final tgtNode = byId[tgtId];
        if (srcNode != null) {
          final idx = srcNode.fields.indexWhere((f) => f.name == fk.fromColumn);
          if (idx >= 0) {
            final orig = srcNode.fields[idx];
            srcNode.fields[idx] = SchemaFieldSpec(
              name: orig.name,
              typeLabel: orig.typeLabel,
              pk: orig.pk,
              fk: true,
              isRefTarget: orig.isRefTarget,
              linkedTable: fk.toTable,
            );
          }
        }
        if (tgtNode != null) {
          final idx = tgtNode.fields.indexWhere((f) => f.name == fk.toColumn);
          if (idx >= 0) {
            final orig = tgtNode.fields[idx];
            tgtNode.fields[idx] = SchemaFieldSpec(
              name: orig.name,
              typeLabel: orig.typeLabel,
              pk: orig.pk,
              fk: orig.fk,
              isRefTarget: true,
              linkedTable: orig.linkedTable ?? fk.fromTable,
            );
          }
        }
        if (srcId == tgtId) continue;
        if (srcNode == null || tgtNode == null) continue;
        edges.add(
          SchemaEdgeData(
            id: 'e${edgeId++}',
            sourceId: srcId,
            targetId: tgtId,
            sourceField: fk.fromColumn,
            targetField: fk.toColumn,
          ),
        );
      }

      layoutSchemaNodes(nodes, edges, mode: tab.layoutMode);

      tab.nodes
        ..clear()
        ..addAll(nodes);
      tab.edges
        ..clear()
        ..addAll(edges);
      tab.isLoaded = true;
    } catch (e) {
      tab.error = e.toString();
    } finally {
      tab.isLoading = false;
      AppState.instance.notifyChange();
      if (mounted) setState(() {});
    }
  }

  void _setLayoutMode(SchemaLayoutMode m) {
    final tab = widget.tab;
    if (tab.layoutMode == m) return;
    tab.layoutMode = m;
    layoutSchemaNodes(tab.nodes, tab.edges, mode: m);
    AppState.instance.notifyChange();
    setState(() {});
  }

  void _onCardActivated(String nodeId) {
    final tab = widget.tab;
    SchemaNodeData? n;
    for (final node in tab.nodes) {
      if (node.id == nodeId) {
        n = node;
        break;
      }
    }
    if (n == null) return;
    AppState.instance.openOrFocusTable(
      connectionId: tab.connectionId,
      schema: n.schema,
      table: n.tableName,
      estimatedRows: -1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: palette.surfaceRaised,
            border: Border(bottom: BorderSide(color: palette.border)),
          ),
          child: Row(
            children: [
              Text(
                tab.isLoaded
                    ? '${tab.nodes.length} tables • ${tab.edges.length} relationships'
                    : 'Schema',
                style: TextStyle(
                  color: palette.text,
                  fontSize: palette.bodyFontSize,
                ),
              ),
              const SizedBox(width: 12),
              _LayoutModeButton(
                label: 'LR',
                tooltip: 'Left to right (roots on left, leaves on right)',
                isSelected: tab.layoutMode == SchemaLayoutMode.lr,
                onPressed: () => _setLayoutMode(SchemaLayoutMode.lr),
              ),
              const SizedBox(width: 4),
              _LayoutModeButton(
                label: 'TB',
                tooltip: 'Top to bottom',
                isSelected: tab.layoutMode == SchemaLayoutMode.tb,
                onPressed: () => _setLayoutMode(SchemaLayoutMode.tb),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Zoom out',
                icon: const Icon(Icons.remove, size: 18),
                onPressed: tab.isLoaded
                    ? () => _canvasCtrl.zoomBy(1 / 1.5)
                    : null,
              ),
              IconButton(
                tooltip: 'Fit to view',
                icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
                onPressed: tab.isLoaded ? () => _canvasCtrl.fitView() : null,
              ),
              IconButton(
                tooltip: 'Zoom in',
                icon: const Icon(Icons.add, size: 18),
                onPressed: tab.isLoaded ? () => _canvasCtrl.zoomBy(1.5) : null,
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh schema',
                icon: tab.isLoading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                onPressed: tab.isLoading
                    ? null
                    : () => _loadSchema(force: true),
              ),
            ],
          ),
        ),
        Expanded(
          child: tab.error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      tab.error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                )
              : !tab.isLoaded
              ? Center(
                  child: tab.isLoading
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('Loading schema...'),
                          ],
                        )
                      : const Text('Loading schema...'),
                )
              : SchemaCanvas(
                  controller: _canvasCtrl,
                  nodes: tab.nodes,
                  edges: tab.edges,
                  pan: tab.pan,
                  scale: tab.scale,
                  onPanChanged: (p) {
                    tab.pan = p;
                    AppState.instance.notifyChange();
                    setState(() {});
                  },
                  onScaleChanged: (s) {
                    tab.scale = s;
                    AppState.instance.notifyChange();
                    setState(() {});
                  },
                  selectedId: tab.selectedId,
                  onSelectedChanged: (id) {
                    tab.selectedId = id;
                    AppState.instance.notifyChange();
                    setState(() {});
                  },
                  onCompactToggled: (id, willBeCompact) {
                    AppState.instance.notifyChange();
                  },
                  onCardActivated: _onCardActivated,
                  cardActivateTooltip: 'Open this table',
                ),
        ),
      ],
    );
  }
}

class _LayoutModeButton extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool isSelected;
  final VoidCallback onPressed;
  const _LayoutModeButton({
    required this.label,
    required this.tooltip,
    required this.isSelected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isSelected ? theme.colorScheme.primary : palette.field,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: palette.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? theme.colorScheme.onPrimary : palette.text,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
