part of '../sidebar.dart';

/// A non-interactive sub-header: a metadata `display.group` inside a
/// schema, or the "Queries & dashboards" section.
class _GroupHeaderRow extends StatelessWidget {
  const _GroupHeaderRow({required this.label, this.indent = 24});
  final String label;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(indent, 6.0, 4.0, 0.0),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.hintColor,
          letterSpacing: 0.5,
          fontSize: 10.0,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _QueryRow extends StatelessWidget {
  const _QueryRow({required this.query, required this.connectionId});
  final NamedQuerySpec query;
  final String connectionId;

  void _open() {
    final existing = AppState.instance.tabs.whereType<NamedQueryTab>().where(
      (tab) => tab.connectionId == connectionId && tab.queryId == query.id,
    );
    if (existing.isNotEmpty) {
      AppState.instance.selectTab(existing.first.id);
      return;
    }
    AppState.instance.openTab(
      NamedQueryTab(
        connectionId: connectionId,
        queryId: query.id,
        label: query.label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DescriptionTooltip(
      markdown: '**${query.label}**\n\n${query.description ?? ''}',
      child: InkWell(
        onTap: _open,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20.0, 3.0, 4.0, 3.0),
          child: Row(
            children: [
              Icon(Icons.manage_search, size: 13.0, color: theme.hintColor),
              const SizedBox(width: 6.0),
              Expanded(
                child: Text(
                  query.group == null
                      ? query.label
                      : '${query.group} ▸ ${query.label}',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardRow extends StatelessWidget {
  const _DashboardRow({
    required this.dashboardId,
    required this.label,
    required this.connectionId,
  });
  final String? dashboardId;
  final String label;
  final String connectionId;

  void _open() {
    final existing = AppState.instance.tabs.whereType<DashboardTab>().where(
      (tab) =>
          tab.connectionId == connectionId && tab.dashboardId == dashboardId,
    );
    if (existing.isNotEmpty) {
      AppState.instance.selectTab(existing.first.id);
      return;
    }
    AppState.instance.openTab(
      DashboardTab(
        connectionId: connectionId,
        dashboardId: dashboardId,
        label: label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: _open,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20.0, 3.0, 4.0, 3.0),
        child: Row(
          children: [
            Icon(Icons.dashboard_outlined, size: 13.0, color: theme.hintColor),
            const SizedBox(width: 6.0),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
