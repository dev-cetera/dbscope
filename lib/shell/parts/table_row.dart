part of '../sidebar.dart';

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.schema,
    required this.table,
    required this.connectionId,
    required this.tableColor,
    this.isSelected = false,
    this.isRelated = false,
  });
  final String schema;
  final TableInfo table;
  final String connectionId;
  final bool isSelected;
  final bool isRelated;
  final Color tableColor;

  void _openTable() {
    // If a navigator is currently active, the sidebar IS its column 0 —
    // clicking a table swaps the navigator's path to that table rather
    // than opening a redundant TableTab. This shortcut is the only
    // table-opening path that branches on the active tab type; the
    // explicit "Open as Table" action in the context menu always opens
    // a fresh TableTab.
    final active = AppState.instance.active;
    if (active is NavigatorTab && active.connectionId == connectionId) {
      active.steps
        ..clear()
        ..add(RowListStep(schema: schema, table: table.name));
      AppState.instance.notifyChange();
      return;
    }
    AppState.instance.openOrFocusTable(
      connectionId: connectionId,
      schema: schema,
      table: table.name,
      estimatedRows: table.estimatedRows,
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final actionContext = SidebarTableActionContext(
      buildContext: context,
      connectionId: connectionId,
      schema: schema,
      table: table.name,
      estimatedRows: table.estimatedRows,
    );
    final actions = SidebarTableActionRegistry.instance.visibleFor(
      actionContext,
    );
    final entries = <AppMenuEntry<String>>[];
    for (var i = 0; i < actions.length; i++) {
      final tableAction = actions[i];
      if (tableAction.startsGroup && i > 0) {
        entries.add(const AppMenuEntry.divider());
      }
      entries.add(
        AppMenuEntry(
          value: tableAction.id,
          label: tableAction.label,
          icon: tableAction.icon,
        ),
      );
    }
    final selected = await showAppContextMenu<String>(
      context: context,
      globalPosition: position,
      items: entries,
    );
    if (selected == null || !context.mounted) return;
    final action = actions.firstWhere((candidate) => candidate.id == selected);
    await action.onSelected(actionContext);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = isSelected
        ? theme.colorScheme.primaryContainer
        : (isRelated ? tableColor.withValues(alpha: 0.28) : Colors.transparent);
    return GestureDetector(
      onSecondaryTapDown: (details) => _showContextMenu(context, details.globalPosition),
      onLongPressStart: (details) => _showContextMenu(context, details.globalPosition),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          border: isSelected ? Border.all(color: theme.colorScheme.primary, width: 1.5) : null,
        ),
        child: InkWell(
          onTap: _openTable,
          child: _withDescription(
            Padding(
              padding: const EdgeInsets.fromLTRB(32.0, 3.0, 4.0, 3.0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      table.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: isSelected || isRelated ? FontWeight.w600 : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (table.estimatedRows >= 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 4.0, right: 2.0),
                      child: Text(
                        _fmt(table.estimatedRows),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                          fontSize: 11.0,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Wraps [child] in a tooltip with the table's metadata description.
  Widget _withDescription(Widget child) {
    final text = MetadataCache.instance
        .snapshotFor(connectionId)
        ?.index
        .describeTable(schema, table.name)
        .toMarkdown();
    if (text == null || text.isEmpty) return child;
    return DescriptionTooltip(markdown: text, child: child);
  }

  String _fmt(int rows) {
    if (rows < 1000) return '$rows';
    if (rows < 1_000_000) return '${(rows / 1000).toStringAsFixed(1)}K';
    if (rows < 1_000_000_000) {
      return '${(rows / 1_000_000).toStringAsFixed(1)}M';
    }
    return '${(rows / 1_000_000_000).toStringAsFixed(1)}B';
  }
}
