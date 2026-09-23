part of '../navigator_view.dart';

// ---------------------------------------------------------------------------
// Column 1: list of tables
// ---------------------------------------------------------------------------

class TableListColumn extends StatefulWidget {
  final NavigatorTab tab;
  final int index;
  const TableListColumn({super.key, required this.tab, required this.index});

  @override
  State<TableListColumn> createState() => _TableListColumnState();
}

class _TableListColumnState extends State<TableListColumn> {
  List<SchemaInfo> _schemas = const [];
  final Map<String, List<TableInfo>> _tables = {};
  final Set<String> _expanded = <String>{};
  bool _loading = false;
  String? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  DbExecutor? _conn() =>
      ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _load() async {
    final conn = _conn();
    if (conn == null) {
      setState(() => _error = 'No connection.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = SchemaCatalog(conn);
      final schemas = await catalog.listSchemas();
      final tables = <String, List<TableInfo>>{};
      final expanded = <String>{};
      for (final s in schemas.where((s) => !s.isSystem)) {
        tables[s.name] = await catalog.listTables(s.name);
        expanded.add(s.name);
      }
      if (!mounted) return;
      setState(() {
        _schemas = schemas;
        _tables
          ..clear()
          ..addAll(tables);
        _expanded
          ..clear()
          ..addAll(expanded);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = classify(e).message;
        _loading = false;
      });
    }
  }

  void _openTable(SchemaInfo s, TableInfo t) {
    final selected = widget.tab.selectedTableAt(widget.index);
    if (selected == '${s.name}.${t.name}') {
      widget.tab.truncateTo(widget.index);
    } else {
      widget.tab.pushFrom(
        widget.index,
        RowListStep(schema: s.name, table: t.name),
      );
    }
    AppState.instance.notifyChange();
  }

  void _toggleSchema(String name) {
    setState(() {
      if (_expanded.contains(name)) {
        _expanded.remove(name);
      } else {
        _expanded.add(name);
      }
    });
  }

  List<TableInfo> _filtered(String schema) {
    final all = _tables[schema] ?? const [];
    if (_filter.isEmpty) return all;
    final f = _filter.toLowerCase();
    return all.where((t) => t.name.toLowerCase().contains(f)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.tab.selectedTableAt(widget.index);
    // Compute related-table keys (FK in either direction) for color-coding.
    final related = <String>{};
    if (selected != null) {
      for (final fk in widget.tab.foreignKeys) {
        if (fk.fromKey == selected) related.add(fk.toKey);
        if (fk.toKey == selected) related.add(fk.fromKey);
      }
    }
    return AppPanel(
      rightBorder: true,
      title: 'Tables',
      subtitle: _loading ? 'loading…' : null,
      trailing: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh, size: 16),
        onPressed: _loading ? null : _load,
      ),
      filter: TextField(
        decoration: const InputDecoration(
          hintText: 'Filter tables…',
          isDense: true,
          prefixIcon: Icon(Icons.search, size: 16),
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => setState(() => _filter = v.trim()),
      ),
      child: _error != null
          ? Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          : ListView(
              children: [
                for (final s in _schemas)
                  ..._schemaRows(s, selected, related, theme),
              ],
            ),
    );
  }

  List<Widget> _schemaRows(
    SchemaInfo s,
    String? selected,
    Set<String> related,
    ThemeData theme,
  ) {
    final tables = _filtered(s.name);
    if (_filter.isNotEmpty && tables.isEmpty) return const [];
    return [
      InkWell(
        onTap: () => _toggleSchema(s.name),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          child: Row(
            children: [
              Icon(
                _expanded.contains(s.name)
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 14,
                color: theme.hintColor,
              ),
              Icon(
                s.isSystem ? Icons.folder_outlined : Icons.folder,
                size: 14,
                color: s.isSystem ? theme.hintColor : theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.name,
                  style: TextStyle(
                    fontWeight: s.isSystem
                        ? FontWeight.normal
                        : FontWeight.w600,
                    color: s.isSystem ? theme.hintColor : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      if (_expanded.contains(s.name))
        for (final t in tables)
          _TableEntry(
            schemaName: s.name,
            table: t,
            isSelected: selected == '${s.name}.${t.name}',
            isRelated: related.contains('${s.name}.${t.name}'),
            onTap: () => _openTable(s, t),
          ),
    ];
  }
}

class _TableEntry extends StatelessWidget {
  final String schemaName;
  final TableInfo table;
  final bool isSelected;
  final bool isRelated;
  final VoidCallback onTap;

  const _TableEntry({
    required this.schemaName,
    required this.table,
    required this.isSelected,
    required this.isRelated,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isView = table.kind == 'VIEW';
    final bg = isSelected
        ? theme.colorScheme.primaryContainer
        : isRelated
        ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.55)
        : Colors.transparent;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: bg,
        padding: const EdgeInsets.fromLTRB(28, 3, 8, 3),
        child: Row(
          children: [
            Icon(
              isView ? Icons.visibility_outlined : Icons.table_chart_outlined,
              size: 12,
              color: isView
                  ? theme.hintColor
                  : isRelated && !isSelected
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.secondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                table.name,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: isSelected || isRelated ? FontWeight.w600 : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isRelated && !isSelected)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.link,
                  size: 11,
                  color: theme.colorScheme.tertiary,
                ),
              ),
            const Icon(Icons.chevron_right, size: 14),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row-list column (column 2 onward when listing rows of a table)
// ---------------------------------------------------------------------------
