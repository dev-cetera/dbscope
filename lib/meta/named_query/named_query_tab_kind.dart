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
    final t = tab as NamedQueryTab;
    final queryId = t.queryId;
    if (queryId == null) return null;
    return {
      'kind': 'named_query',
      'id': t.id,
      'connectionId': t.connectionId,
      'queryId': queryId,
      'label': t.label,
      'pinned': t.pinned,
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
    final t = tab as NamedQueryTab;
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
