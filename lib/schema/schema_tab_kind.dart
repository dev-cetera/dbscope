import 'package:flutter/material.dart';
import 'package:schema_viewer/schema_viewer.dart';

import '../tabs/tab_kind.dart';
import 'schema_tab.dart';
import 'schema_view.dart';

final schemaTabKind = TabKind(
  id: 'schema',
  modelType: SchemaTab,
  icon: Icons.schema_outlined,
  buildView: (tab) => SchemaTabView(key: ValueKey(tab.id), tab: tab as SchemaTab),
  serialize: (tab) {
    final schemaTab = tab as SchemaTab;
    return {
      'kind': 'schema',
      'id': schemaTab.id,
      'connectionId': schemaTab.connectionId,
      'layoutMode': schemaTab.layoutMode == SchemaLayoutMode.lr ? 'lr' : 'tb',
      'pinned': schemaTab.pinned,
    };
  },
  deserialize: (j) {
    final layoutModeName = j['layoutMode'] as String? ?? 'lr';
    return SchemaTab(
      id: j['id'] as String?,
      connectionId: j['connectionId'] as String? ?? '',
      layoutMode: layoutModeName == 'tb' ? SchemaLayoutMode.tb : SchemaLayoutMode.lr,
    );
  },
);
