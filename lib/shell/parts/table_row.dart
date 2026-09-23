part of '../sidebar.dart';

class _TableRow extends StatelessWidget {
  final String schema;
  final TableInfo table;
  final String connectionId;
  final bool isSelected;
  final bool isRelated;
  final Color tableColor;
  const _TableRow({
    required this.schema,
    required this.table,
    required this.connectionId,
    required this.tableColor,
    this.isSelected = false,
    this.isRelated = false,
  });

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

  void _showContextMenu(BuildContext context, Offset position) async {
    final ctx = SidebarTableActionContext(
      buildContext: context,
      connectionId: connectionId,
      schema: schema,
      table: table.name,
      estimatedRows: table.estimatedRows,
    );
    final actions = SidebarTableActionRegistry.instance.visibleFor(ctx);
    final entries = <AppMenuEntry<String>>[];
    for (var i = 0; i < actions.length; i++) {
      final a = actions[i];
      if (a.startsGroup && i > 0) {
        entries.add(const AppMenuEntry.divider());
      }
      entries.add(AppMenuEntry(value: a.id, label: a.label, icon: a.icon));
    }
    final selected = await showAppContextMenu<String>(
      context: context,
      globalPosition: position,
      items: entries,
    );
    if (selected == null || !context.mounted) return;
    final action = actions.firstWhere((a) => a.id == selected);
    await action.onSelected(ctx);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = isSelected
        ? theme.colorScheme.primaryContainer
        : (isRelated ? tableColor.withValues(alpha: 0.28) : Colors.transparent);
    return GestureDetector(
      onSecondaryTapDown: (d) => _showContextMenu(context, d.globalPosition),
      onLongPressStart: (d) => _showContextMenu(context, d.globalPosition),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          border: isSelected
              ? Border.all(color: theme.colorScheme.primary, width: 1.5)
              : null,
        ),
        child: InkWell(
          onTap: _openTable,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 3, 4, 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    table.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: isSelected || isRelated
                          ? FontWeight.w600
                          : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (table.estimatedRows >= 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 2),
                    child: Text(
                      _fmt(table.estimatedRows),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
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
