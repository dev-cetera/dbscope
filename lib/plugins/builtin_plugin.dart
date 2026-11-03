import 'package:ai_broker/ai_broker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../jobs/job_tab_kind.dart';
import '../json_viewer/json_tab_kind.dart' show jsonTabKind;
import '../linked/linked_tab_kind.dart';
import '../navigator/navigator_tab_kind.dart';
import '../query/query_tab_kind.dart';
import '../schema/schema_tab_kind.dart';
import '../shell/crash_log_menu.dart';
import '../shell/sidebar_table_actions_default.dart';
import '../table/table_tab_kind.dart';
import 'dbscope_plugin.dart';

/// Bundle of host-built-in contributions exposed as one
/// [DbscopePlugin] so the registration shape is identical to a
/// third-party plugin's. Owns:
///
/// - the core tab kinds (Table, Query, Navigator, Linked, Schema,
/// JSON, Job). Query is unified: AI prompting lives inside the
/// standard Query tab. A legacy `kind: 'ai'` alias is registered
/// for read-only migration of old persisted tabs.
/// - the built-in sidebar table-row actions (Open as Table /
/// Navigator / Linked, Copy name, Configure soft-delete, Copy to
/// another DB)
/// - the three packaged AI brokers (OpenAI, Anthropic, Gemini) from
/// `package:ai_broker`
/// - File ▸ Show crash log, on desktop
class BuiltinPlugin extends DbscopePlugin {
  @override
  String get id => 'builtin';
  @override
  String get label => 'DBScope built-ins';

  @override
  void register(DbscopeHost host) {
    // Tab kinds.
    host.tabs
      ..register(tableTabKind)
      ..register(queryTabKind)
      ..register(legacyAiQueryTabKind)
      ..register(navigatorTabKind)
      ..register(linkedTabKind)
      ..register(schemaTabKind)
      ..register(jobTabKind)
      ..register(jsonTabKind);

    // Sidebar table-row actions.
    registerDefaultSidebarTableActions();

    // File ▸ Show crash log (desktop: the web build has no log file).
    if (!kIsWeb) host.menus.register(crashLogMenuContribution);

    // AI brokers.
    host.aiBrokers
      ..register(OpenAiBroker())
      ..register(AnthropicBroker())
      ..register(GeminiBroker());
  }
}
