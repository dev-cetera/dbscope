import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../../connection/registry.dart';
import '../../tabs/tab_kind.dart';
import '../../tabs/tab_model.dart';
import '../../util/listenable_state_mixin.dart';
import '../charts/chart_view.dart';
import '../meta_cache.dart';

/// A grid of charts from schema metadata: one `dashboard` row (its
/// `charts` list), or — with no id — every chart that isn't row-scoped.
class DashboardTab extends TabModel {
  DashboardTab({
    super.id,
    required super.connectionId,
    required this.dashboardId,
    required this.label,
  });
  final String? dashboardId;
  final String label;

  @override
  String get title => label;
}

class DashboardView extends StatefulWidget {
  const DashboardView({super.key, required this.tab});
  final DashboardTab tab;

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView>
    with ListenableStateMixin {
  @override
  List<Listenable> get listenables => [MetadataCache.instance];

  /// Bumped by Refresh so every card reloads.
  var _generation = 0;

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final snapshot = MetadataCache.instance.snapshotFor(tab.connectionId);
    final executor = ConnectionRegistry.instance.connectionFor(
      tab.connectionId,
    );
    if (snapshot == null || executor == null) {
      return const EmptyState(icon: Icons.power_off, message: 'Not connected.');
    }
    final index = snapshot.index;
    final spec = tab.dashboardId == null
        ? null
        : index.dashboards.where((d) => d.id == tab.dashboardId).firstOrNull;
    final charts = spec == null
        ? [
            for (final c in index.charts)
              if (!c.rowScoped) c,
          ]
        : [
            for (final id in spec.chartIds) ?index.chartById(id),
          ];
    if (tab.dashboardId != null && spec == null) {
      return EmptyState(
        icon: Icons.dashboard_outlined,
        message:
            'The dashboard "${tab.label}" no longer exists in the metadata.',
      );
    }
    final columns = spec?.columns ?? 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          titleIcon: Icons.dashboard_outlined,
          title: spec?.label ?? tab.label,
          trailing: IconButton(
            tooltip: 'Refresh all charts',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () => setState(() => _generation++),
          ),
        ),
        Expanded(
          child: charts.isEmpty
              ? const EmptyState(
                  icon: Icons.insert_chart_outlined,
                  message: 'No charts in the metadata yet.',
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    const gap = 12.0;
                    final width =
                        (constraints.maxWidth - gap * (columns + 1)) / columns;
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(gap),
                      child: Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (final c in charts)
                            SizedBox(
                              width: width,
                              child: MetaChartCard(
                                key: ValueKey('${c.id}#$_generation'),
                                chart: c,
                                executor: executor,
                                height: 260,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

final dashboardTabKind = TabKind(
  id: 'dashboard',
  modelType: DashboardTab,
  icon: Icons.dashboard_outlined,
  buildView: (tab) =>
      DashboardView(key: ValueKey(tab.id), tab: tab as DashboardTab),
  serialize: (tab) {
    final t = tab as DashboardTab;
    return {
      'kind': 'dashboard',
      'id': t.id,
      'connectionId': t.connectionId,
      'dashboardId': t.dashboardId,
      'label': t.label,
      'pinned': t.pinned,
    };
  },
  deserialize: (j) => DashboardTab(
    id: j['id'] as String?,
    connectionId: j['connectionId'] as String? ?? '',
    dashboardId: j['dashboardId'] as String?,
    label: j['label'] as String? ?? 'Dashboard',
  ),
);
