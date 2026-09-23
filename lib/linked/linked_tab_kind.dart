import 'package:flutter/material.dart';

import '../tabs/tab_kind.dart';
import 'linked_tab.dart';
import 'linked_view.dart';

final TabKind linkedTabKind = TabKind(
  id: 'linked',
  modelType: LinkedTab,
  icon: Icons.hub_outlined,
  buildView: (tab) =>
      LinkedTabView(key: ValueKey(tab.id), tab: tab as LinkedTab),
  serialize: (tab) {
    final t = tab as LinkedTab;
    return {
      'kind': 'linked',
      'id': t.id,
      'connectionId': t.connectionId,
      'seedSchema': t.seedSchema,
      'seedTable': t.seedTable,
      'pinned': t.pinned,
    };
  },
  deserialize: (j) => LinkedTab(
    id: j['id'] as String?,
    connectionId: j['connectionId'] as String? ?? '',
    seedSchema: j['seedSchema'] as String?,
    seedTable: j['seedTable'] as String?,
  ),
);
