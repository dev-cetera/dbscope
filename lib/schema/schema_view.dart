import 'dart:async';

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
  const SchemaTabView({super.key, required this.tab});
  final SchemaTab tab;

  @override
  State<SchemaTabView> createState() => _SchemaTabViewState();
}

class _SchemaTabViewState extends State<SchemaTabView> {
  late final _canvasController = SchemaCanvasController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.tab.isLoaded) unawaited(_loadSchema());
    });
  }

  DbExecutor? _executor() => ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _loadSchema({bool force = false}) async {
    final tab = widget.tab;
    if (tab.isLoading) return;
    tab.isLoading = true;
    tab.error = null;
    AppState.instance.notifyChange();
    try {
      final executor = _executor();
      if (executor == null) {
        tab.error = 'No connection.';
        return;
      }
      final catalog = SchemaCatalog(executor);
      final schemas = await catalog.listSchemas();
      final userSchemas = schemas
          .where((schema) => !schema.isSystem)
          .map((schema) => schema.name)
          .toList();
      // Gather diagrammable tables across every user schema first, so we
      // can spot table names that collide across schemas. A table living
      // in more than one schema (e.g. `public.groups` and `auth.groups`)
      // would otherwise render as two identical-looking "groups" cards,
      // since the card header shows only the bare table name.
      final diagramTables = <(String schema, TableInfo table)>[];
      for (final schemaName in userSchemas) {
        final tables = await catalog.listTables(schemaName);
        for (final table in tables) {
          if (table.kind != 'BASE TABLE' && table.kind != 'VIEW') continue;
          diagramTables.add((schemaName, table));
        }
      }
      final nameCounts = <String, int>{};
      for (final (_, table) in diagramTables) {
        nameCounts[table.name] = (nameCounts[table.name] ?? 0) + 1;
      }

      final nodes = <SchemaNodeData>[];
      for (final (schemaName, table) in diagramTables) {
        final columns = force
            ? await catalog.listColumns(schemaName, table.name)
            : (tab.cachedColumns(schemaName, table.name) ??
                  await catalog.listColumns(schemaName, table.name));
        tab.setCachedColumns(schemaName, table.name, columns);
        final primaryKeyColumns = (await catalog.primaryKey(
          schemaName,
          table.name,
        )).toSet();
        nodes.add(
          SchemaNodeData(
            id: '$schemaName.${table.name}',
            schema: schemaName,
            tableName: table.name,
            // Disambiguate cards when the same table name exists in more
            // than one schema; single-schema names stay uncluttered.
            subtitle: (nameCounts[table.name] ?? 0) > 1 ? schemaName : null,
            fields: [
              for (final column in columns)
                SchemaFieldSpec(
                  name: column.name,
                  typeLabel: column.typeName,
                  pk: primaryKeyColumns.contains(column.name),
                ),
            ],
          ),
        );
      }

      final foreignKeys = await catalog.listForeignKeys();
      final byId = {for (final node in nodes) node.id: node};
      final edges = <SchemaEdgeData>[];
      var edgeId = 0;
      for (final foreignKey in foreignKeys) {
        final srcId = '${foreignKey.fromSchema}.${foreignKey.fromTable}';
        final tgtId = '${foreignKey.toSchema}.${foreignKey.toTable}';
        final srcNode = byId[srcId];
        final tgtNode = byId[tgtId];
        if (srcNode != null) {
          final fieldIndex = srcNode.fields.indexWhere(
            (field) => field.name == foreignKey.fromColumn,
          );
          if (fieldIndex >= 0) {
            final orig = srcNode.fields[fieldIndex];
            srcNode.fields[fieldIndex] = SchemaFieldSpec(
              name: orig.name,
              typeLabel: orig.typeLabel,
              pk: orig.pk,
              fk: true,
              isRefTarget: orig.isRefTarget,
              linkedTable: foreignKey.toTable,
            );
          }
        }
        if (tgtNode != null) {
          final fieldIndex = tgtNode.fields.indexWhere(
            (field) => field.name == foreignKey.toColumn,
          );
          if (fieldIndex >= 0) {
            final orig = tgtNode.fields[fieldIndex];
            tgtNode.fields[fieldIndex] = SchemaFieldSpec(
              name: orig.name,
              typeLabel: orig.typeLabel,
              pk: orig.pk,
              fk: orig.fk,
              isRefTarget: true,
              linkedTable: orig.linkedTable ?? foreignKey.fromTable,
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
            sourceField: foreignKey.fromColumn,
            targetField: foreignKey.toColumn,
            dashed: foreignKey.isVirtual,
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

  void _setLayoutMode(SchemaLayoutMode mode) {
    final tab = widget.tab;
    if (tab.layoutMode == mode) return;
    tab.layoutMode = mode;
    layoutSchemaNodes(tab.nodes, tab.edges, mode: mode);
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
          height: 36.0,
          padding: const EdgeInsets.symmetric(horizontal: 10.0),
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
              const SizedBox(width: 12.0),
              _LayoutModeButton(
                label: 'LR',
                tooltip: 'Left to right (roots on left, leaves on right)',
                isSelected: tab.layoutMode == SchemaLayoutMode.lr,
                onPressed: () => _setLayoutMode(SchemaLayoutMode.lr),
              ),
              const SizedBox(width: 4.0),
              _LayoutModeButton(
                label: 'TB',
                tooltip: 'Top to bottom',
                isSelected: tab.layoutMode == SchemaLayoutMode.tb,
                onPressed: () => _setLayoutMode(SchemaLayoutMode.tb),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Zoom out',
                icon: const Icon(Icons.remove, size: 18.0),
                onPressed: tab.isLoaded ? () => _canvasController.zoomBy(1 / 1.5) : null,
              ),
              IconButton(
                tooltip: 'Fit to view',
                icon: const Icon(
                  Icons.center_focus_strong_outlined,
                  size: 18.0,
                ),
                onPressed: tab.isLoaded ? () => _canvasController.fitView() : null,
              ),
              IconButton(
                tooltip: 'Zoom in',
                icon: const Icon(Icons.add, size: 18.0),
                onPressed: tab.isLoaded ? () => _canvasController.zoomBy(1.5) : null,
              ),
              const SizedBox(width: 8.0),
              IconButton(
                tooltip: 'Refresh schema',
                icon: tab.isLoading
                    ? const SizedBox(
                        width: 14.0,
                        height: 14.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : const Icon(Icons.refresh, size: 18.0),
                onPressed: tab.isLoading ? null : () => _loadSchema(force: true),
              ),
            ],
          ),
        ),
        Expanded(
          child: tab.error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
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
                            SizedBox(height: 12.0),
                            Text('Loading schema...'),
                          ],
                        )
                      : const Text('Loading schema...'),
                )
              : SchemaCanvas(
                  controller: _canvasController,
                  nodes: tab.nodes,
                  edges: tab.edges,
                  pan: tab.pan,
                  scale: tab.scale,
                  onPanChanged: (pan) {
                    tab.pan = pan;
                    AppState.instance.notifyChange();
                    setState(() {});
                  },
                  onScaleChanged: (scale) {
                    tab.scale = scale;
                    AppState.instance.notifyChange();
                    setState(() {});
                  },
                  selectedId: tab.selectedId,
                  onSelectedChanged: (id) {
                    tab.selectedId = id;
                    AppState.instance.notifyChange();
                    setState(() {});
                  },
                  onCompactToggled: (id, {required willBeCompact}) {
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
  const _LayoutModeButton({
    required this.label,
    required this.tooltip,
    required this.isSelected,
    required this.onPressed,
  });
  final String label;
  final String tooltip;
  final bool isSelected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 3.0),
          decoration: BoxDecoration(
            color: isSelected ? theme.colorScheme.primary : palette.field,
            borderRadius: BorderRadius.circular(3.0),
            border: Border.all(color: palette.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? theme.colorScheme.onPrimary : palette.text,
              fontSize: 11.0,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
