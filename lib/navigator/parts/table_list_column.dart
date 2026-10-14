part of '../navigator_view.dart';

// ---------------------------------------------------------------------------
// Column 1: list of tables
// ---------------------------------------------------------------------------

class TableListColumn extends StatefulWidget {
  const TableListColumn({super.key, required this.tab, required this.index});
  final NavigatorTab tab;
  final int index;

  @override
  State<TableListColumn> createState() => _TableListColumnState();
}

class _TableListColumnState extends State<TableListColumn> {
  List<SchemaInfo> _schemas = const [];
  final Map<String, List<TableInfo>> _tables = {};
  final _expanded = <String>{};
  var _loading = false;
  String? _error;
  var _filter = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  DbExecutor? _executor() =>
      ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _load() async {
    final executor = _executor();
    if (executor == null) {
      setState(() => _error = 'No connection.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = SchemaCatalog(executor);
      final schemas = await catalog.listSchemas();
      final tables = <String, List<TableInfo>>{};
      final expanded = <String>{};
      for (final schema in schemas.where((schema) => !schema.isSystem)) {
        tables[schema.name] = await catalog.listTables(schema.name);
        expanded.add(schema.name);
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

  void _openTable(SchemaInfo schema, TableInfo table) {
    final selected = widget.tab.selectedTableAt(widget.index);
    if (selected == '${schema.name}.${table.name}') {
      widget.tab.truncateTo(widget.index);
    } else {
      widget.tab.pushFrom(
        widget.index,
        RowListStep(schema: schema.name, table: table.name),
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
    final filter = _filter.toLowerCase();
    return all
        .where((table) => table.name.toLowerCase().contains(filter))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.tab.selectedTableAt(widget.index);
    // Compute related-table keys (FK in either direction) for color-coding.
    final related = <String>{};
    if (selected != null) {
      for (final foreignKey in widget.tab.foreignKeys) {
        if (foreignKey.fromKey == selected) related.add(foreignKey.toKey);
        if (foreignKey.toKey == selected) related.add(foreignKey.fromKey);
      }
    }
    return AppPanel(
      rightBorder: true,
      title: 'Tables',
      subtitle: _loading ? 'loading…' : null,
      trailing: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh, size: 16.0),
        onPressed: _loading ? null : _load,
      ),
      filter: TextField(
        decoration: const InputDecoration(
          hintText: 'Filter tables…',
          isDense: true,
          prefixIcon: Icon(Icons.search, size: 16.0),
          border: OutlineInputBorder(),
        ),
        onChanged: (value) => setState(() => _filter = value.trim()),
      ),
      child: _error != null
          ? Padding(
              padding: const EdgeInsets.all(8.0),
              child: SelectableText(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          : ListView(
              children: [
                for (final schema in _schemas)
                  ..._schemaRows(schema, selected, related, theme),
              ],
            ),
    );
  }

  List<Widget> _schemaRows(
    SchemaInfo schema,
    String? selected,
    Set<String> related,
    ThemeData theme,
  ) {
    final tables = _filtered(schema.name);
    if (_filter.isNotEmpty && tables.isEmpty) return const [];
    return [
      InkWell(
        onTap: () => _toggleSchema(schema.name),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6.0, 4.0, 6.0, 4.0),
          child: Row(
            children: [
              Icon(
                _expanded.contains(schema.name)
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 14.0,
                color: theme.hintColor,
              ),
              Icon(
                schema.isSystem ? Icons.folder_outlined : Icons.folder,
                size: 14.0,
                color: schema.isSystem
                    ? theme.hintColor
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 6.0),
              Expanded(
                child: Text(
                  schema.name,
                  style: TextStyle(
                    fontWeight: schema.isSystem
                        ? FontWeight.normal
                        : FontWeight.w600,
                    color: schema.isSystem ? theme.hintColor : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      if (_expanded.contains(schema.name))
        for (final table in tables)
          _TableEntry(
            schemaName: schema.name,
            table: table,
            isSelected: selected == '${schema.name}.${table.name}',
            isRelated: related.contains('${schema.name}.${table.name}'),
            onTap: () => _openTable(schema, table),
          ),
    ];
  }
}

class _TableEntry extends StatelessWidget {
  const _TableEntry({
    required this.schemaName,
    required this.table,
    required this.isSelected,
    required this.isRelated,
    required this.onTap,
  });
  final String schemaName;
  final TableInfo table;
  final bool isSelected;
  final bool isRelated;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isView = table.kind == 'VIEW';
    final backgroundColor = isSelected
        ? theme.colorScheme.primaryContainer
        : isRelated
        ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.55)
        : Colors.transparent;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: backgroundColor,
        padding: const EdgeInsets.fromLTRB(28.0, 3.0, 8.0, 3.0),
        child: Row(
          children: [
            Icon(
              isView ? Icons.visibility_outlined : Icons.table_chart_outlined,
              size: 12.0,
              color: isView
                  ? theme.hintColor
                  : isRelated && !isSelected
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.secondary,
            ),
            const SizedBox(width: 6.0),
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
                padding: const EdgeInsets.only(right: 4.0),
                child: Icon(
                  Icons.link,
                  size: 11.0,
                  color: theme.colorScheme.tertiary,
                ),
              ),
            const Icon(Icons.chevron_right, size: 14.0),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row-list column (column 2 onward when listing rows of a table)
// ---------------------------------------------------------------------------
