import 'package:flutter/material.dart';

import '../tabs/tab_kind.dart';
import 'json_tab.dart';
import 'json_tab_view.dart';

/// JsonTabs are transient — they're spawned from a JSON cell viewer
/// and don't survive a restart. So no serialize/deserialize.
final TabKind jsonTabKind = TabKind(
  id: 'json',
  modelType: JsonTab,
  icon: Icons.data_object,
  buildView: (tab) => JsonTabView(key: ValueKey(tab.id), tab: tab as JsonTab),
);
