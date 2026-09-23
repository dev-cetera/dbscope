import 'package:ai_broker/ai_broker.dart' show AiBrokerRegistry;

import '../db/plugin.dart';
import '../shell/menu_spec.dart';
import '../shell/sidebar_table_actions.dart';
import '../shell/theme_registry.dart';
import '../tabs/tab_kind.dart';

/// Surface a plugin uses to wire itself into the host. Every
/// host-provided extension point appears here as a getter; adding a
/// new extension point = one new getter + the matching registry.
abstract class DbscopeHost {
  ThemeRegistry get themes;
  ConnectionKindRegistry get connections;
  TabKindRegistry get tabs;
  MenuContributionRegistry get menus;
  SidebarTableActionRegistry get sidebarActions;
  AiBrokerRegistry get aiBrokers;
}

/// Single entry point implemented by every plugin in the workspace.
///
/// Each plugin's `register` wires all of its contributions through the
/// supplied [DbscopeHost]. The host calls `register` exactly once at
/// startup. Plugins must be additive: registering the same plugin
/// twice should be idempotent (the per-domain registries handle
/// re-registration by replacing prior entries).
///
/// Removing a plugin = deleting its package folder + dropping its
/// `register(...)` line from `main.dart`. Core code never references a
/// plugin by name.
abstract class DbscopePlugin {
  /// Stable plugin id. Used for diagnostics and conflict detection.
  String get id;

  /// Short human-readable label.
  String get label;

  void register(DbscopeHost host);
}

/// Default host implementation backed by the per-domain registry
/// singletons.
class _DefaultHost implements DbscopeHost {
  const _DefaultHost();
  @override
  ThemeRegistry get themes => ThemeRegistry.instance;
  @override
  ConnectionKindRegistry get connections => ConnectionKindRegistry.instance;
  @override
  TabKindRegistry get tabs => TabKindRegistry.instance;
  @override
  MenuContributionRegistry get menus => MenuContributionRegistry.instance;
  @override
  SidebarTableActionRegistry get sidebarActions =>
      SidebarTableActionRegistry.instance;
  @override
  AiBrokerRegistry get aiBrokers => AiBrokerRegistry.instance;
}

/// Aggregating registry. main.dart calls
/// `DbscopePluginRegistry.instance.register(SomePlugin())` once per
/// plugin; each plugin's `register(host)` runs immediately, wiring its
/// contributions into the appropriate sub-registries.
class DbscopePluginRegistry {
  DbscopePluginRegistry._();
  static final DbscopePluginRegistry instance = DbscopePluginRegistry._();

  static const DbscopeHost _host = _DefaultHost();

  final List<DbscopePlugin> _plugins = [];

  void register(DbscopePlugin plugin) {
    _plugins.add(plugin);
    plugin.register(_host);
  }

  List<DbscopePlugin> get all => List.unmodifiable(_plugins);
}
