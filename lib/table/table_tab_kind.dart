import 'package:flutter/material.dart';

import '../grid/data_grid.dart';
import '../tabs/tab_kind.dart';
import 'table_tab.dart';
import 'table_tab_view.dart';

GridViewMode _viewModeFrom(Object? value) {
  if (value is String) {
    for (final mode in GridViewMode.values) {
      if (mode.name == value) return mode;
    }
  }
  return GridViewMode.typed;
}

final tableTabKind = TabKind(
  id: 'table',
  modelType: TableTab,
  icon: Icons.table_chart_outlined,
  buildView: (tab) => TableTabView(key: ValueKey(tab.id), tab: tab as TableTab),
  serialize: (tab) {
    final tableTab = tab as TableTab;
    return {
      'kind': 'table',
      'id': tableTab.id,
      'connectionId': tableTab.connectionId,
      'schema': tableTab.schema,
      'table': tableTab.table,
      'estimatedRows': tableTab.estimatedRows,
      'pinned': tableTab.pinned,
      'viewMode': tableTab.viewMode.name,
    };
  },
  deserialize: (j) {
    final schema = j['schema'] as String?;
    final table = j['table'] as String?;
    if (schema == null || table == null) return null;
    return TableTab(
      id: j['id'] as String?,
      connectionId: j['connectionId'] as String? ?? '',
      schema: schema,
      table: table,
      estimatedRows: (j['estimatedRows'] as num?)?.toInt() ?? -1,
    )..viewMode = _viewModeFrom(j['viewMode']);
  },
  isRunning: (tab) {
    final tableTab = tab as TableTab;
    return tableTab.isLoading || tableTab.isLoadingMore;
  },
  footerSummary: (tab) {
    final tableTab = tab as TableTab;
    final rows = tableTab.estimatedRows < 0 ? '?' : '~${_compact(tableTab.estimatedRows)}';
    var summary = '$rows rows';
    if (tableTab.error != null) {
      summary += ' • error';
    } else if (tableTab.elapsed != null && !tableTab.isLoading) {
      summary += ' • ${tableTab.elapsed!.inMilliseconds}ms';
    }
    return summary;
  },
);

String _compact(int rows) {
  if (rows < 1000) return '$rows';
  if (rows < 1000000) return '${(rows / 1000).toStringAsFixed(1)}K';
  if (rows < 1000000000) return '${(rows / 1000000).toStringAsFixed(1)}M';
  return '${(rows / 1000000000).toStringAsFixed(1)}B';
}
