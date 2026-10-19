import 'package:flutter/material.dart';

import '../grid/data_grid.dart';
import '../tabs/tab_kind.dart';
import 'query_tab.dart';
import 'query_tab_view.dart';

GridViewMode _viewModeFrom(Object? value) {
  if (value is String) {
    for (final mode in GridViewMode.values) {
      if (mode.name == value) return mode;
    }
  }
  return GridViewMode.typed;
}

QueryTab _deserialize(Map<String, Object?> j) {
  // Accepts both the unified `query` shape and the legacy `ai` shape
  // (kind: 'ai', generatedSql, prompt, focusSchema/Table). Legacy AI
  // tabs come back with the generated SQL pre-populated in the editor.
  final legacyAi = j['kind'] == 'ai';
  final sql = (j['sql'] as String?) ?? (legacyAi ? (j['generatedSql'] as String?) ?? '' : '');
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

final queryTabKind = TabKind(
  id: 'query',
  modelType: QueryTab,
  icon: Icons.code,
  buildView: (tab) => QueryTabView(key: ValueKey(tab.id), tab: tab as QueryTab),
  serialize: (tab) {
    final queryTab = tab as QueryTab;
    return {
      'kind': 'query',
      'id': queryTab.id,
      'connectionId': queryTab.connectionId,
      'sql': queryTab.sql,
      'prompt': queryTab.prompt,
      'focusSchema': queryTab.focusSchema,
      'focusTable': queryTab.focusTable,
      'historyRailOpen': queryTab.historyRailOpen,
      'titleOverride': queryTab.titleOverride,
      'savedName': queryTab.savedName,
      'pinned': queryTab.pinned,
      'viewMode': queryTab.viewMode.name,
    };
  },
  deserialize: _deserialize,
  isRunning: (tab) {
    final queryTab = tab as QueryTab;
    return queryTab.isLoading || queryTab.isAsking;
  },
  footerSummary: (tab) {
    final queryTab = tab as QueryTab;
    final rows = queryTab.data?.rows.length ?? 0;
    var summary = '$rows rows';
    if (queryTab.truncated) summary += ' • truncated at 10k';
    if (queryTab.error != null) {
      summary += ' • error';
    } else if (queryTab.elapsed != null && !queryTab.isLoading) {
      summary += ' • ${queryTab.elapsed!.inMilliseconds}ms';
    }
    return summary;
  },
);

/// Legacy alias so persisted tabs saved with `kind: 'ai'` continue to
/// restore as the unified [QueryTab]. New tabs always serialize as
/// `kind: 'query'`, so this is migrate-on-read only.
final legacyAiQueryTabKind = TabKind(
  id: 'ai',
  modelType: _LegacyAiSentinel,
  icon: Icons.auto_awesome,
  buildView: (_) => const SizedBox.shrink(),
  deserialize: _deserialize,
);

class _LegacyAiSentinel {
  const _LegacyAiSentinel._();
}
