import 'package:flutter/material.dart';

import '../../tabs/tab_kind.dart';
import 'named_query_tab.dart';
import 'named_query_view.dart';

/// Named queries persist across restarts (by id — the SQL is re-read from
/// the metadata); ad-hoc action results are transient.
final namedQueryTabKind = TabKind(
  id: 'named_query',
  modelType: NamedQueryTab,
  icon: Icons.manage_search,
  buildView: (tab) =>
      NamedQueryView(key: ValueKey(tab.id), tab: tab as NamedQueryTab),
  serialize: (tab) {
    final namedQueryTab = tab as NamedQueryTab;
    final queryId = namedQueryTab.queryId;
    if (queryId == null) return null;
    return {
      'kind': 'named_query',
      'id': namedQueryTab.id,
      'connectionId': namedQueryTab.connectionId,
      'queryId': queryId,
      'label': namedQueryTab.label,
      'pinned': namedQueryTab.pinned,
    };
  },
  deserialize: (j) {
    final queryId = j['queryId'] as String?;
    if (queryId == null) return null;
    return NamedQueryTab(
      id: j['id'] as String?,
      connectionId: j['connectionId'] as String? ?? '',
      queryId: queryId,
      label: j['label'] as String? ?? queryId,
      autoRun: false,
    );
  },
  isRunning: (tab) => (tab as NamedQueryTab).isLoading,
  footerSummary: (tab) {
    final namedQueryTab = tab as NamedQueryTab;
    final rows = namedQueryTab.data?.rows.length ?? 0;
    var summary = '$rows rows';
    if (namedQueryTab.truncated) summary += ' • truncated at 10k';
    if (namedQueryTab.error != null) {
      summary += ' • error';
    } else if (namedQueryTab.elapsed != null && !namedQueryTab.isLoading) {
      summary += ' • ${namedQueryTab.elapsed!.inMilliseconds}ms';
    }
    return summary;
  },
);
