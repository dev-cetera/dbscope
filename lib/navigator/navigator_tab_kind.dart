import 'package:flutter/material.dart';

import '../tabs/tab_kind.dart';
import 'navigator_tab.dart';
import 'navigator_view.dart';

final TabKind navigatorTabKind = TabKind(
  id: 'navigator',
  modelType: NavigatorTab,
  icon: Icons.view_column_outlined,
  buildView: (tab) =>
      NavigatorTabView(key: ValueKey(tab.id), tab: tab as NavigatorTab),
  serialize: (tab) {
    final t = tab as NavigatorTab;
    return {
      'kind': 'navigator',
      'id': t.id,
      'connectionId': t.connectionId,
      'pinned': t.pinned,
    };
  },
  deserialize: (j) => NavigatorTab(
    id: j['id'] as String?,
    connectionId: j['connectionId'] as String? ?? '',
  ),
);
