import 'package:flutter/material.dart';
import 'package:schema_viewer/schema_viewer.dart';

import '../tabs/tab_kind.dart';
import 'schema_tab.dart';
import 'schema_view.dart';

final TabKind schemaTabKind = TabKind(
  id: 'schema',
  modelType: SchemaTab,
  icon: Icons.schema_outlined,
  buildView: (tab) =>
      SchemaTabView(key: ValueKey(tab.id), tab: tab as SchemaTab),
  serialize: (tab) {
    final t = tab as SchemaTab;
    return {
      'kind': 'schema',
      'id': t.id,
      'connectionId': t.connectionId,
      'layoutMode': t.layoutMode == SchemaLayoutMode.lr ? 'lr' : 'tb',
      'pinned': t.pinned,
    };
  },
  deserialize: (j) {
    final modeStr = j['layoutMode'] as String? ?? 'lr';
    return SchemaTab(
      id: j['id'] as String?,
      connectionId: j['connectionId'] as String? ?? '',
      layoutMode: modeStr == 'tb' ? SchemaLayoutMode.tb : SchemaLayoutMode.lr,
    );
  },
);
