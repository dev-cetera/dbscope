library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../catalog/schema_catalog.dart';
import '../connection/connection_picker.dart';
import '../connection/registry.dart';
import '../db/executor.dart';
import '../meta/dashboard/dashboard_tab.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../meta/named_query/named_query_tab.dart';
import '../meta/ui/description_tooltip.dart';
import '../navigator/navigator_tab.dart';
import '../util/listenable_state_mixin.dart';
import 'app_state.dart';
import 'relationship_gutter.dart';
import 'sidebar_table_actions.dart';

part 'parts/connection_picker.dart';
part 'parts/table_row.dart';
part 'parts/meta_rows.dart';

/// Cross-widget channel: lets the app shell focus the sidebar's filter
/// TextField when Cmd+F is pressed. The sidebar registers its focus
/// node on mount; the shortcut handler calls [requestFilterFocus].
class SidebarFocusController {
  SidebarFocusController._();
  static final instance = SidebarFocusController._();

  FocusNode? _filterFocus;

  // Paired with `detach`; a setter would hide that lifecycle pairing.
  // ignore: use_setters_to_change_properties
  void attach(FocusNode node) {
    _filterFocus = node;
  }

  void detach(FocusNode node) {
    if (identical(_filterFocus, node)) _filterFocus = null;
  }

  void requestFilterFocus() {
    final focusNode = _filterFocus;
    if (focusNode == null) return;
    // Defer to after the current frame so the sidebar has rebuilt
    // (e.g. when we just toggled visibility on).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusNode.requestFocus();
    });
  }
}

class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> with ListenableStateMixin {
  @override
  List<Listenable> get listenables => [AppState.instance];

  /// The metadata snapshot the listing was built under; a new one (reload,
  /// "View as…") can change which tables exist for this user.
  MetaSnapshot? _metaUsed;

  void _onMetadataChange() {
    if (!mounted) return;
    final id = _registry.activeId;
    final snapshot = MetadataCache.instance.snapshotFor(id);
    if (snapshot == null || snapshot.status != MetaLoadStatus.ready) return;
    if (identical(snapshot, _metaUsed)) return;
    _metaUsed = snapshot;
    if (_registry.isConnected) unawaited(_reload(keepExpansion: true));
  }

  final ConnectionRegistry _registry = ConnectionRegistry.instance;
  final _filterController = TextEditingController();
  final _filterFocus = FocusNode(debugLabel: 'sidebar-filter');
  final _scrollController = ScrollController();
  List<SchemaInfo> _schemas = [];
  final Map<String, List<TableInfo>> _tablesBySchema = {};
  final _expanded = <String>{};
  List<ForeignKey> _foreignKeys = const [];
  var _loading = false;
  String? _error;
  var _filter = '';
  String? _loadedFor;

  /// Bumped by every reload and by disconnect. A load only applies its
  /// results while its generation is still current, so a slow reload for
  /// connection A can't overwrite the listing of a B the user switched
  /// to mid-flight (both stay open in the registry).
  var _generation = 0;

  bool _isCurrent(int generation) => mounted && generation == _generation;

  @override
  void initState() {
    super.initState();
    _registry.addListener(_onRegistryChange);
    MetadataCache.instance.addListener(_onMetadataChange);
    _metaUsed = MetadataCache.instance.snapshotFor(_registry.activeId);
    SidebarFocusController.instance.attach(_filterFocus);
    if (_registry.isConnected) unawaited(_reload());
  }

  @override
  void dispose() {
    SidebarFocusController.instance.detach(_filterFocus);
    _registry.removeListener(_onRegistryChange);
    MetadataCache.instance.removeListener(_onMetadataChange);
    _scrollController.dispose();
    _filterController.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  void _onRegistryChange() {
    if (!mounted) return;
    final activeId = _registry.activeId;
    if (_registry.isConnected) {
      if (activeId != _loadedFor) {
        unawaited(_reload());
      }
    } else {
      _generation++;
      setState(() {
        _loading = false;
        _schemas = [];
        _tablesBySchema.clear();
        _expanded.clear();
        _foreignKeys = const [];
        _error = _registry.lastError;
        _loadedFor = null;
      });
    }
  }

  /// [keepExpansion]: a metadata refresh of the SAME connection keeps the
  /// schemas the user collapsed or expanded.
  Future<void> _reload({bool keepExpansion = false}) async {
    final executor = _registry.connection;
    final activeId = _registry.activeId;
    if (executor == null || activeId == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _loadedFor = activeId;
    });
    try {
      final catalog = SchemaCatalog(executor);
      final schemas = await catalog.listSchemas();
      if (!_isCurrent(generation)) return;
      setState(() {
        _schemas = schemas;
        _tablesBySchema.clear();
        if (keepExpansion) {
          final names = {for (final schemaInfo in schemas) schemaInfo.name};
          _expanded.removeWhere((name) => !names.contains(name));
        } else {
          _expanded.clear();
          for (final schemaInfo in schemas.where(
            (schemaInfo) => !schemaInfo.isSystem,
          )) {
            _expanded.add(schemaInfo.name);
          }
        }
      });
      for (final schemaInfo in schemas.where(
        (schemaInfo) => !schemaInfo.isSystem,
      )) {
        await _loadTables(
          schemaInfo.name,
          executor: executor,
          generation: generation,
        );
        if (!_isCurrent(generation)) return;
      }
      try {
        final foreignKeys = await catalog.listForeignKeys();
        if (!_isCurrent(generation)) return;
        setState(() => _foreignKeys = foreignKeys);
      } catch (_) {
        if (!_isCurrent(generation)) return;
        setState(() => _foreignKeys = const []);
      }
    } catch (e) {
      if (!_isCurrent(generation)) return;
      setState(() => _error = e.toString());
    } finally {
      if (_isCurrent(generation)) setState(() => _loading = false);
    }
  }

  /// A reload passes the [executor] and [generation] it captured, so a
  /// stale load neither queries the newly active connection with the old
  /// connection's schema names nor writes into its listing. User actions
  /// (expand, refresh) omit them and use the current ones.
  Future<void> _loadTables(
    String schema, {
    DbExecutor? executor,
    int? generation,
  }) async {
    final conn = executor ?? _registry.connection;
    if (conn == null) return;
    final loadGeneration = generation ?? _generation;
    try {
      final catalog = SchemaCatalog(conn);
      final tables = await catalog.listTables(schema);
      if (!_isCurrent(loadGeneration)) return;
      setState(() => _tablesBySchema[schema] = tables);
    } catch (e, st) {
      if (!_isCurrent(loadGeneration)) return;
      // Surface the real cause instead of silently rendering an empty
      // schema. Without this, an HTTP-backed driver that returns a
      // wrapped error ("Command failure - DB Exception ...") looks
      // identical to "no tables".
      debugPrint('listTables($schema) failed: $e\n$st');
      setState(() {
        _tablesBySchema[schema] = [];
        _error = 'Tables in "$schema": $e';
      });
    }
  }

  void _toggleSchema(SchemaInfo schema) {
    setState(() {
      if (_expanded.contains(schema.name)) {
        _expanded.remove(schema.name);
      } else {
        _expanded.add(schema.name);
        if (!_tablesBySchema.containsKey(schema.name)) {
          unawaited(_loadTables(schema.name));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConnectionPicker(registry: _registry, onReload: _reload),
          Padding(
            padding: const EdgeInsets.fromLTRB(8.0, 0.0, 8.0, 8.0),
            child: TextField(
              controller: _filterController,
              focusNode: _filterFocus,
              decoration: InputDecoration(
                hintText: 'Filter tables… (Cmd+F)',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18.0),
                border: const OutlineInputBorder(),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18.0),
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filter = '');
                        },
                      ),
              ),
              onChanged: (value) => setState(() => _filter = value.trim()),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2.0),
          if (_error != null) ErrorView(message: _error!, onRetry: _reload),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  String? _selectedKey() {
    final tab = AppState.instance.active;
    if (tab is TableTab) return '${tab.schema}.${tab.table}';
    if (tab is NavigatorTab) {
      for (final step in tab.steps) {
        if (step is RowListStep) return '${step.schema}.${step.table}';
      }
    }
    return null;
  }

  Widget _buildList() {
    final activeId = _registry.activeId;
    if (activeId == null || !_registry.isConnected) {
      return EmptyState(
        icon: _registry.profiles.isEmpty ? Icons.power_settings_new : Icons.power,
        iconSize: 36.0,
        message: _registry.profiles.isEmpty
            ? 'No connection.\nUse Connection > Add…'
            : 'Pick a connection above.',
      );
    }
    final snapshot = MetadataCache.instance.snapshotFor(activeId);
    final rows = <_FlatRow>[];
    for (final schema in _schemas) {
      final tables = _filteredTables(schema.name);
      if (_filter.isNotEmpty && tables.isEmpty) continue;
      rows.add(_FlatRow.schema(schema));
      if (!_expanded.contains(schema.name)) continue;
      // Metadata `display.group` folds tables into labelled groups;
      // ungrouped tables follow.
      final grouped = <String, List<TableInfo>>{};
      final ungrouped = <TableInfo>[];
      for (final table in tables) {
        final group = snapshot?.index.groupOf(schema.name, table.name);
        if (group == null) {
          ungrouped.add(table);
        } else {
          (grouped[group] ??= []).add(table);
        }
      }
      final groupNames = grouped.keys.toList()..sort();
      for (final groupName in groupNames) {
        rows.add(_FlatRow.group(groupName));
        for (final table in grouped[groupName]!) {
          rows.add(_FlatRow.table(schema.name, table));
        }
      }
      if (groupNames.isNotEmpty && ungrouped.isNotEmpty) {
        rows.add(const _FlatRow.group('Other'));
      }
      for (final table in ungrouped) {
        rows.add(_FlatRow.table(schema.name, table));
      }
    }
    if (snapshot != null) {
      final policy = snapshot.policy;
      final filterText = _filter.toLowerCase();
      final queries = [
        for (final query in snapshot.index.queries)
          if (policy.forQuery(query.id).canSeeValues &&
              (filterText.isEmpty || query.label.toLowerCase().contains(filterText)))
            query,
      ];
      final dashboards = snapshot.index.dashboards;
      final hasCharts = snapshot.index.charts.any((chart) => !chart.rowScoped);
      if (queries.isNotEmpty || dashboards.isNotEmpty || hasCharts) {
        rows.add(const _FlatRow.metaHeader());
        for (final dashboard in dashboards) {
          rows.add(_FlatRow.dashboard(dashboard.id, dashboard.label));
        }
        if (hasCharts && dashboards.isEmpty) {
          rows.add(const _FlatRow.dashboard(null, 'All charts'));
        }
        for (final query in queries) {
          rows.add(_FlatRow.query(query));
        }
      }
    }

    final gutterItems = [
      for (final row in rows) GutterItem(tableKey: row.tableKey),
    ];
    final selectedKey = _selectedKey();
    final related = relatedTables(_foreignKeys, selectedKey);
    // Walk the visible rows in display order so adjacent-row collision
    // avoidance happens against what the user actually sees next to each
    // other (schema headers are skipped — tables across a header are still
    // visually adjacent).
    final tableColors = buildTableColorMap(
      rows.map((row) => row.tableKey).whereType<String>(),
    );

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: kGutterWidth),
          child: ListView.builder(
            controller: _scrollController,
            itemCount: rows.length,
            itemExtent: kGutterRowHeight,
            itemBuilder: (_, i) {
              final row = rows[i];
              final rowSchema = row.schema;
              if (rowSchema != null) {
                return _SchemaRow(
                  schema: rowSchema,
                  connectionId: activeId,
                  isExpanded: _expanded.contains(rowSchema.name),
                  onToggle: () => _toggleSchema(rowSchema),
                  onSecondaryTapDown: (globalPosition) =>
                      _showSchemaContextMenu(rowSchema, globalPosition),
                );
              }
              if (row.groupLabel != null) {
                return _GroupHeaderRow(label: row.groupLabel!);
              }
              if (row.isMetaHeader) {
                return const _GroupHeaderRow(
                  label: 'Queries & dashboards',
                  indent: 8.0,
                );
              }
              if (row.query != null) {
                return _QueryRow(query: row.query!, connectionId: activeId);
              }
              if (row.isDashboard) {
                return _DashboardRow(
                  dashboardId: row.dashboardId,
                  label: row.dashboardLabel!,
                  connectionId: activeId,
                );
              }
              final tableKey = '${row.tableSchema!}.${row.table!.name}';
              return _TableRow(
                schema: row.tableSchema!,
                table: row.table!,
                connectionId: activeId,
                isSelected: tableKey == selectedKey,
                isRelated: related.contains(tableKey),
                tableColor: tableColors[tableKey]!,
              );
            },
          ),
        ),
        Positioned(
          left: 0.0,
          top: 0.0,
          bottom: 0.0,
          width: kGutterWidth,
          child: IgnorePointer(
            child: _ScrollAwarePaint(
              controller: _scrollController,
              builder: (position) => CustomPaint(
                painter: RelationshipGutterPainter(
                  items: gutterItems,
                  edges: _foreignKeys,
                  selectedKey: selectedKey,
                  scroll: position,
                  tableColors: tableColors,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showSchemaContextMenu(
    SchemaInfo schema,
    Offset globalPosition,
  ) async {
    final picked = await showAppContextMenu<String>(
      context: context,
      globalPosition: globalPosition,
      items: const [
        AppMenuEntry(
          value: 'copy',
          label: 'Copy schema name',
          icon: Icons.copy,
        ),
        AppMenuEntry(
          value: 'refresh',
          label: 'Refresh tables',
          icon: Icons.refresh,
        ),
      ],
    );
    if (picked == 'copy') {
      await Clipboard.setData(ClipboardData(text: schema.name));
      if (!mounted) return;
      showToast(context, 'Copied "${schema.name}"');
    } else if (picked == 'refresh') {
      _tablesBySchema.remove(schema.name);
      await _loadTables(schema.name);
    }
  }

  List<TableInfo> _filteredTables(String schema) {
    final all = _tablesBySchema[schema] ?? const [];
    if (_filter.isEmpty) return all;
    final filterText = _filter.toLowerCase();
    return all.where((table) => table.name.toLowerCase().contains(filterText)).toList();
  }
}

/// One schema header row in the sidebar list: expand arrow, folder icon and
/// name, wrapped in a metadata description tooltip when the schema has one.
class _SchemaRow extends StatelessWidget {
  const _SchemaRow({
    required this.schema,
    required this.connectionId,
    required this.isExpanded,
    required this.onToggle,
    required this.onSecondaryTapDown,
  });
  final SchemaInfo schema;
  final String connectionId;
  final bool isExpanded;
  final VoidCallback onToggle;
  final void Function(Offset globalPosition) onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = MetadataCache.instance
        .snapshotFor(connectionId)
        ?.index
        .describeSchema(schema.name)
        .toMarkdown();
    final row = GestureDetector(
      onSecondaryTapDown: (details) => onSecondaryTapDown(details.globalPosition),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            children: [
              Icon(
                isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                size: 16.0,
                color: theme.hintColor,
              ),
              const SizedBox(width: 4.0),
              Icon(
                schema.isSystem ? Icons.folder_outlined : Icons.folder,
                size: 14.0,
                color: schema.isSystem ? theme.hintColor : theme.colorScheme.primary,
              ),
              const SizedBox(width: 6.0),
              Expanded(
                child: Text(
                  schema.name,
                  style: TextStyle(
                    fontWeight: schema.isSystem ? FontWeight.normal : FontWeight.w600,
                    color: schema.isSystem ? theme.hintColor : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (description == null || description.isEmpty) return row;
    return DescriptionTooltip(markdown: description, child: row);
  }
}

class _FlatRow {
  const _FlatRow._({
    this.schema,
    this.tableSchema,
    this.table,
    this.groupLabel,
    this.isMetaHeader = false,
    this.query,
    this.isDashboard = false,
    this.dashboardId,
    this.dashboardLabel,
  });
  _FlatRow.schema(SchemaInfo schemaInfo) : this._(schema: schemaInfo);
  _FlatRow.table(String schema, TableInfo table) : this._(tableSchema: schema, table: table);
  const _FlatRow.group(String label) : this._(groupLabel: label);
  const _FlatRow.metaHeader() : this._(isMetaHeader: true);
  const _FlatRow.query(NamedQuerySpec query) : this._(query: query);
  const _FlatRow.dashboard(String? id, String label)
    : this._(isDashboard: true, dashboardId: id, dashboardLabel: label);
  final SchemaInfo? schema;
  final String? tableSchema;
  final TableInfo? table;

  /// A metadata `display.group` sub-header inside a schema.
  final String? groupLabel;

  /// The "Queries & dashboards" header.
  final bool isMetaHeader;
  final NamedQuerySpec? query;
  final bool isDashboard;
  final String? dashboardId;
  final String? dashboardLabel;

  String? get tableKey => table == null ? null : '$tableSchema.${table!.name}';
}

class _ScrollAwarePaint extends StatefulWidget {
  const _ScrollAwarePaint({required this.controller, required this.builder});
  final ScrollController controller;
  final Widget Function(ScrollPosition position) builder;

  @override
  State<_ScrollAwarePaint> createState() => _ScrollAwarePaintState();
}

class _ScrollAwarePaintState extends State<_ScrollAwarePaint> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
    // The controller only fires on position changes — not on its first
    // attach to a viewport. Re-render after the first frame so the gutter
    // appears as soon as the ListView has attached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.hasClients) {
      return const SizedBox.shrink();
    }
    return widget.builder(widget.controller.position);
  }
}
