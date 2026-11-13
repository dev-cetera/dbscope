import 'package:flutter/material.dart';

import '../tabs/tab_kind.dart';
import 'agent_tab.dart';
import 'agent_tab_view.dart';

/// Agent tabs are transient: no serialize/deserialize.
final agentTabKind = TabKind(
  id: 'agent',
  modelType: AgentTab,
  icon: Icons.smart_toy_outlined,
  buildView: (tab) => AgentTabView(key: ValueKey(tab.id), tab: tab as AgentTab),
  isRunning: (tab) => (tab as AgentTab).isWorking,
);
