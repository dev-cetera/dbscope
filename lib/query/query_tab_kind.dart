import 'package:flutter/material.dart';

import '../grid/data_grid.dart';
import '../tabs/tab_kind.dart';
import 'query_tab.dart';
import 'query_tab_view.dart';

GridViewMode _viewModeFrom(Object? v) {
  if (v is String) {
    for (final m in GridViewMode.values) {
      if (m.name == v) return m;
    }
  }
  return GridViewMode.typed;
}

QueryTab _deserialize(Map<String, Object?> j) {
  // Accepts both the unified `query` shape and the legacy `ai` shape
  // (kind: 'ai', generatedSql, prompt, focusSchema/Table). Legacy AI
  // tabs come back with the generated SQL pre-populated in the editor.
  final legacyAi = j['kind'] == 'ai';
  final sql =
      (j['sql'] as String?) ??
      (legacyAi ? (j['generatedSql'] as String?) ?? '' : '');
  return QueryTab(
    id: j['id'] as String?,
    connectionId: j['connectionId'] as String? ?? '',
    sql: sql,
    prompt: (j['prompt'] as String?) ?? '',
    focusSchema: j['focusSchema'] as String?,
    focusTable: j['focusTable'] as String?,
    historyRailOpen: (j['historyRailOpen'] as bool?) ?? false,
    titleOverride: j['titleOverride'] as String?,
    savedName: j['savedName'] as String?,
  )..viewMode = _viewModeFrom(j['viewMode']);
}

final TabKind queryTabKind = TabKind(
  id: 'query',
  modelType: QueryTab,
  icon: Icons.code,
  buildView: (tab) => QueryTabView(key: ValueKey(tab.id), tab: tab as QueryTab),
  serialize: (tab) {
    final t = tab as QueryTab;
    return {
      'kind': 'query',
      'id': t.id,
      'connectionId': t.connectionId,
      'sql': t.sql,
      'prompt': t.prompt,
      'focusSchema': t.focusSchema,
      'focusTable': t.focusTable,
      'historyRailOpen': t.historyRailOpen,
      'titleOverride': t.titleOverride,
      'savedName': t.savedName,
      'pinned': t.pinned,
      'viewMode': t.viewMode.name,
    };
  },
  deserialize: _deserialize,
  isRunning: (tab) {
    final t = tab as QueryTab;
    return t.isLoading || t.isAsking;
  },
  footerSummary: (tab) {
    final t = tab as QueryTab;
    final rows = t.data?.rows.length ?? 0;
    var s = '$rows rows';
    if (t.truncated) s += ' • truncated at 10k';
    if (t.error != null) {
      s += ' • error';
    } else if (t.elapsed != null && !t.isLoading) {
      s += ' • ${t.elapsed!.inMilliseconds}ms';
    }
    return s;
  },
);

/// Legacy alias so persisted tabs saved with `kind: 'ai'` continue to
/// restore as the unified [QueryTab]. New tabs always serialize as
/// `kind: 'query'`, so this is migrate-on-read only.
final TabKind legacyAiQueryTabKind = TabKind(
  id: 'ai',
  modelType: _LegacyAiSentinel,
  icon: Icons.auto_awesome,
  buildView: (_) => const SizedBox.shrink(),
  deserialize: _deserialize,
);

class _LegacyAiSentinel {
  const _LegacyAiSentinel._();
}
