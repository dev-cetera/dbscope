library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../catalog/schema_catalog.dart';
import '../connection/connection_picker.dart';
import '../connection/registry.dart';
import '../navigator/navigator_tab.dart';
import '../util/listenable_state_mixin.dart';
import 'app_state.dart';
import 'relationship_gutter.dart';
import 'sidebar_table_actions.dart';

part 'parts/connection_picker.dart';
part 'parts/table_row.dart';

/// Cross-widget channel: lets the app shell focus the sidebar's filter
/// TextField when Cmd+F is pressed. The sidebar registers its focus
/// node on mount; the shortcut handler calls [requestFilterFocus].
class SidebarFocusController {
  SidebarFocusController._();
  static final SidebarFocusController instance = SidebarFocusController._();

  FocusNode? _filterFocus;

  void attach(FocusNode node) {
    _filterFocus = node;
  }

  void detach(FocusNode node) {
    if (identical(_filterFocus, node)) _filterFocus = null;
  }

  void requestFilterFocus() {
    final n = _filterFocus;
    if (n == null) return;
    // Defer to after the current frame so the sidebar has rebuilt
    // (e.g. when we just toggled visibility on).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      n.requestFocus();
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

  final _registry = ConnectionRegistry.instance;
  final _filterController = TextEditingController();
  final _filterFocus = FocusNode(debugLabel: 'sidebar-filter');
  final _scrollController = ScrollController();
  List<SchemaInfo> _schemas = [];
  final Map<String, List<TableInfo>> _tablesBySchema = {};
  final Set<String> _expanded = <String>{};
  List<ForeignKey> _fks = const [];
  bool _loading = false;
  String? _error;
  String _filter = '';
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    _registry.addListener(_onRegistryChange);
    SidebarFocusController.instance.attach(_filterFocus);
    if (_registry.isConnected) _reload();
  }

  @override
  void dispose() {
    SidebarFocusController.instance.detach(_filterFocus);
    _registry.removeListener(_onRegistryChange);
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
        _reload();
      }
    } else {
      setState(() {
        _schemas = [];
        _tablesBySchema.clear();
        _expanded.clear();
        _fks = const [];
        _error = _registry.lastError;
        _loadedFor = null;
      });
    }
  }

  Future<void> _reload() async {
    final conn = _registry.connection;
    final activeId = _registry.activeId;
    if (conn == null || activeId == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _loadedFor = activeId;
    });
    try {
      final catalog = SchemaCatalog(conn);
      final schemas = await catalog.listSchemas();
      if (!mounted) return;
      setState(() {
        _schemas = schemas;
        _tablesBySchema.clear();
        _expanded.clear();
        for (final s in schemas.where((s) => !s.isSystem)) {
          _expanded.add(s.name);
        }
      });
      for (final s in schemas.where((s) => !s.isSystem)) {
        await _loadTables(s.name);
      }
      try {
        final fks = await catalog.listForeignKeys();
        if (!mounted) return;
        setState(() => _fks = fks);
      } catch (_) {
        if (!mounted) return;
        setState(() => _fks = const []);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadTables(String schema) async {
    final conn = _registry.connection;
    if (conn == null) return;
    try {
      final catalog = SchemaCatalog(conn);
      final tables = await catalog.listTables(schema);
      if (!mounted) return;
      setState(() => _tablesBySchema[schema] = tables);
    } catch (e, st) {
      if (!mounted) return;
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
          _loadTables(schema.name);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConnectionPicker(registry: _registry, onReload: _reload),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: TextField(
              controller: _filterController,
              focusNode: _filterFocus,
              decoration: InputDecoration(
                hintText: 'Filter tables… (Cmd+F)',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                border: const OutlineInputBorder(),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filter = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _filter = v.trim()),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null) ErrorView(message: _error!, onRetry: _reload),
          Expanded(child: _buildList(theme)),
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

  Widget _buildList(ThemeData theme) {
    final activeId = _registry.activeId;
    if (activeId == null || !_registry.isConnected) {
      return EmptyState(
        icon: _registry.profiles.isEmpty
            ? Icons.power_settings_new
            : Icons.power,
        iconSize: 36,
        message: _registry.profiles.isEmpty
            ? 'No connection.\nUse Connection > Add…'
            : 'Pick a connection above.',
      );
    }
    final rows = <_FlatRow>[];
    for (final schema in _schemas) {
      final tables = _filteredTables(schema.name);
      if (_filter.isNotEmpty && tables.isEmpty) continue;
      rows.add(_FlatRow.schema(schema));
      if (_expanded.contains(schema.name)) {
        for (final t in tables) {
          rows.add(_FlatRow.table(schema.name, t));
        }
      }
    }

    final gutterItems = [
      for (final r in rows) GutterItem(tableKey: r.tableKey),
    ];
    final selectedKey = _selectedKey();
    final related = relatedTables(_fks, selectedKey);
    // Walk the visible rows in display order so adjacent-row collision
    // avoidance happens against what the user actually sees next to each
    // other (schema headers are skipped — tables across a header are still
    // visually adjacent).
    final tableColors = buildTableColorMap(
      rows.map((r) => r.tableKey).whereType<String>(),
    );

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: kGutterWidth),
          child: ListView.builder(
            controller: _scrollController,
            itemCount: rows.length,
            itemExtent: kGutterRowHeight,
            itemBuilder: (ctx, i) {
              final r = rows[i];
              if (r.schema != null) {
                return _buildSchemaRow(theme, r.schema!);
              }
              final tableKey = '${r.tableSchema!}.${r.table!.name}';
              return _TableRow(
                schema: r.tableSchema!,
                table: r.table!,
                connectionId: activeId,
                isSelected: tableKey == selectedKey,
                isRelated: related.contains(tableKey),
                tableColor: tableColors[tableKey]!,
              );
            },
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: kGutterWidth,
          child: IgnorePointer(
            child: _ScrollAwarePaint(
              controller: _scrollController,
              builder: (position) => CustomPaint(
                painter: RelationshipGutterPainter(
                  items: gutterItems,
                  edges: _fks,
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

  Widget _buildSchemaRow(ThemeData theme, SchemaInfo schema) {
    return GestureDetector(
      onSecondaryTapDown: (d) =>
          _showSchemaContextMenu(schema, d.globalPosition),
      child: InkWell(
        onTap: () => _toggleSchema(schema),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Icon(
                _expanded.contains(schema.name)
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 16,
                color: theme.hintColor,
              ),
              const SizedBox(width: 4),
              Icon(
                schema.isSystem ? Icons.folder_outlined : Icons.folder,
                size: 14,
                color: schema.isSystem
                    ? theme.hintColor
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  schema.name,
                  style: TextStyle(
                    fontWeight: schema.isSystem
                        ? FontWeight.normal
                        : FontWeight.w600,
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
  }

  Future<void> _showSchemaContextMenu(
    SchemaInfo schema,
    Offset globalPos,
  ) async {
    final picked = await showAppContextMenu<String>(
      context: context,
      globalPosition: globalPos,
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
    final f = _filter.toLowerCase();
    return all.where((t) => t.name.toLowerCase().contains(f)).toList();
  }
}

class _FlatRow {
  final SchemaInfo? schema;
  final String? tableSchema;
  final TableInfo? table;

  const _FlatRow._({this.schema, this.tableSchema, this.table});
  _FlatRow.schema(SchemaInfo s) : this._(schema: s);
  _FlatRow.table(String schema, TableInfo t)
    : this._(tableSchema: schema, table: t);

  String? get tableKey => table == null ? null : '$tableSchema.${table!.name}';
}

class _ScrollAwarePaint extends StatefulWidget {
  final ScrollController controller;
  final Widget Function(ScrollPosition position) builder;
  const _ScrollAwarePaint({required this.controller, required this.builder});

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
