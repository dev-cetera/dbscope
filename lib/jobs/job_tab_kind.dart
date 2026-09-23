import 'package:flutter/material.dart';

import '../../tabs/tab_kind.dart';
import 'job_tab.dart';
import 'job_tab_view.dart';

/// JobTabs aren't persisted — the underlying server-side job is part
/// of the server's state, not the window's, and reattaching a tab to
/// a job that may have finished is more confusing than helpful.
final TabKind jobTabKind = TabKind(
  id: 'job',
  modelType: JobTab,
  icon: Icons.task_alt,
  buildView: (tab) => JobTabView(key: ValueKey(tab.id), tab: tab as JobTab),
);
