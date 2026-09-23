import 'package:flutter/material.dart';

import '../grid/data_grid.dart';
import '../tabs/tab_kind.dart';
import 'table_tab.dart';
import 'table_tab_view.dart';

GridViewMode _viewModeFrom(Object? v) {
  if (v is String) {
    for (final m in GridViewMode.values) {
      if (m.name == v) return m;
    }
  }
  return GridViewMode.typed;
}

final TabKind tableTabKind = TabKind(
  id: 'table',
  modelType: TableTab,
  icon: Icons.table_chart_outlined,
  buildView: (tab) => TableTabView(key: ValueKey(tab.id), tab: tab as TableTab),
  serialize: (tab) {
    final t = tab as TableTab;
    return {
      'kind': 'table',
      'id': t.id,
      'connectionId': t.connectionId,
      'schema': t.schema,
      'table': t.table,
      'estimatedRows': t.estimatedRows,
      'pinned': t.pinned,
      'viewMode': t.viewMode.name,
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
    final t = tab as TableTab;
    return t.isLoading || t.isLoadingMore;
  },
  footerSummary: (tab) {
    final t = tab as TableTab;
    final rows = t.estimatedRows < 0 ? '?' : '~${_compact(t.estimatedRows)}';
    var s = '$rows rows';
    if (t.error != null) {
      s += ' • error';
    } else if (t.elapsed != null && !t.isLoading) {
      s += ' • ${t.elapsed!.inMilliseconds}ms';
    }
    return s;
  },
);

String _compact(int rows) {
  if (rows < 1000) return '$rows';
  if (rows < 1000000) return '${(rows / 1000).toStringAsFixed(1)}K';
  if (rows < 1000000000) return '${(rows / 1000000).toStringAsFixed(1)}M';
  return '${(rows / 1000000000).toStringAsFixed(1)}B';
}
