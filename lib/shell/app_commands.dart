import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:key_flow/key_flow.dart';

import '../agent/agent_tab.dart';
import '../ai/settings_dialog.dart';
import '../catalog/dbml_export_flow.dart';
import '../connection/connection_link_flow.dart';
import '../connection/connection_picker.dart';
import '../connection/profile.dart';
import '../connection/registry.dart';
import '../db/sqlite_kind.dart';
import '../linked/linked_tab.dart';
import '../navigator/navigator_tab.dart';
import '../schema/schema_tab.dart';
import 'app_state.dart';
import 'command_registry.dart';
import 'env_dialog.dart';
import 'sidebar.dart';
import 'theme_registry.dart';
import 'ui_prefs.dart';
import 'welcome_dialog.dart';
import 'window_actions.dart';

// The app's commands: one key_flow tree that is at once the menu bar (native
// on macOS, drawn in the window elsewhere), the keyboard shortcuts, the
// command palette, the shortcut sheet and what the AI agent can press.
// Rebuilt whenever the shell notifies, so labels, `enabled` and `checked`
// follow live state; every callback reads the AppState / ConnectionRegistry
// singletons at run time.
//
// The AI agent can run any command not marked `_peopleOnly`: those export
// secrets, change settings or the connection, or open file pickers.

/// Keeps a command away from the AI agent.
const Set<KeySurface> _peopleOnly = {KeySurface.agents};

/// Argument names of the agent-only `open_table` command.
abstract final class _OpenTableArgs {
  static const schema = 'schema';
  static const table = 'table';
}

/// Every top-level menu with its commands, plugin contributions included.
/// [keys] is the window's key_flow controller, for the Help commands that
/// open its panels.
List<KeyNode> buildAppCommands({required KeyFlowController keys}) {
  final state = AppState.instance;
  final registry = ConnectionRegistry.instance;
  final connected = registry.activeId != null;
  final commands = CommandRegistry.instance;

  KeyGroup menu(String label, List<KeyNode> children) => KeyGroup(
    id: commandIdFor(label),
    label: label,
    inMenuBar: true,
    children: [...children, ...commands.commandsFor(label)],
  );

  return [
    menu(AppMenu.file.label, [
      KeyCommand(
        id: 'new_query',
        label: 'New query',
        keys: const ['meta+t'],
        enabled: connected,
        onRun: (_) => _newQuery(),
      ),
      KeyCommand(
        id: 'new_navigator',
        label: 'New navigator',
        keys: const ['meta+shift+t'],
        enabled: connected,
        onRun: (_) => _newNavigator(),
      ),
      KeyCommand(
        id: 'new_linked',
        label: 'New linked view',
        enabled: connected,
        onRun: (_) => _newLinked(),
      ),
      KeyCommand(
        id: 'new_window',
        label: 'New window',
        keys: const ['meta+shift+n'],
        onRun: (_) => WindowActions.spawnWindow(),
      ),
      KeyCommand(
        id: 'new_connection',
        hiddenFrom: _peopleOnly,
        label: 'New connection…',
        onRun: (_) => _addConnection(appContext()),
      ),
      KeyCommand(
        id: 'import_link',
        hiddenFrom: _peopleOnly,
        label: 'Import connection link…',
        onRun: (_) => ConnectionLinkFlow.importAndConnect(appContext()),
      ),
      KeyCommand(
        id: 'export_link',
        hiddenFrom: _peopleOnly,
        label: 'Export connection link…',
        enabled: connected,
        onRun: (_) => _exportConnection(appContext()),
      ),
      KeyCommand(
        id: 'open_db_file',
        hiddenFrom: _peopleOnly,
        label: 'Open .db file…',
        keys: const ['meta+o'],
        onRun: (_) => _openSqliteFile(appContext()),
      ),
      KeyCommand(
        id: 'export_dbml',
        hiddenFrom: _peopleOnly,
        label: 'Export schema as DBML…',
        enabled: connected,
        onRun: (_) => DbmlExportFlow.run(appContext()),
      ),
      const KeyDivider(),
      KeyCommand(
        id: 'environment',
        hiddenFrom: _peopleOnly,
        label: 'Environment…',
        onRun: (_) => showEnvDialog(appContext()),
      ),
      const KeyDivider(),
      KeyCommand(
        id: 'close_tab',
        label: 'Close tab',
        keys: const ['meta+w'],
        enabled: state.active != null,
        onRun: (_) => _closeActiveTab(),
      ),
    ]),
    menu(AppMenu.view.label, [
      KeyCommand(
        id: 'schema',
        label: 'Schema',
        keys: const ['meta+d'],
        enabled: connected,
        onRun: (_) => _openSchema(),
      ),
      KeyCommand(
        id: 'new_navigator',
        label: 'New navigator',
        enabled: connected,
        onRun: (_) => _newNavigator(),
      ),
      KeyCommand(
        id: 'new_linked',
        label: 'New linked view',
        enabled: connected,
        onRun: (_) => _newLinked(),
      ),
      KeyCommand(
        id: 'sidebar',
        label: state.sidebarVisible ? 'Hide sidebar' : 'Show sidebar',
        keys: _metaWithMacControl('b'),
        onRun: (_) => state.toggleSidebarVisible(),
      ),
      KeyCommand(
        id: 'sidebar_side',
        label: 'Toggle sidebar side',
        onRun: (_) => state.toggleSidebar(),
      ),
      KeyCommand(
        id: 'open_table',
        label: 'Open table',
        description: 'Opens a table in a tab, for the user to browse.',
        enabled: connected,
        inputSchema: const {
          'type': 'object',
          'properties': {
            _OpenTableArgs.schema: {'type': 'string'},
            _OpenTableArgs.table: {'type': 'string'},
          },
          'required': [_OpenTableArgs.schema, _OpenTableArgs.table],
        },
        onInput: (_, input) => _openTable(input),
      ),
      KeyCommand(
        id: 'find_table',
        label: 'Find table',
        description: 'Shows the sidebar if hidden and focuses its table filter.',
        keys: _metaWithMacControl('f'),
        onRun: (_) => _findTable(),
      ),
      const KeyDivider(),
      KeyGroup(
        id: 'theme',
        label: 'Theme',
        children: [
          for (final theme in ThemeRegistry.instance.all)
            KeyCommand(
              id: commandIdFor(theme.id),
              label: theme.label,
              checked: state.themeId == theme.id,
              onRun: (_) => state.setThemeId(theme.id),
            ),
        ],
      ),
    ]),
    menu(AppMenu.connection.label, [
      KeyCommand(
        id: 'add',
        hiddenFrom: _peopleOnly,
        label: 'Add…',
        onRun: (_) => _addConnection(appContext()),
      ),
      KeyCommand(
        id: 'export_link',
        hiddenFrom: _peopleOnly,
        label: 'Export as connection link…',
        enabled: connected,
        onRun: (_) => _exportConnection(appContext()),
      ),
      KeyCommand(
        id: 'read_only',
        hiddenFrom: _peopleOnly,
        label: 'Read-only',
        enabled: connected,
        checked: connected && registry.isReadOnly,
        onRun: (_) => _toggleReadOnly(),
      ),
      KeyCommand(
        id: 'disconnect',
        hiddenFrom: _peopleOnly,
        label: 'Disconnect',
        enabled: connected,
        onRun: (_) => registry.disconnect(),
      ),
    ]),
    menu(AppMenu.ai.label, [
      KeyCommand(
        id: 'new_ai_query',
        label: 'New AI query',
        keys: const ['meta+alt+t'],
        enabled: connected,
        onRun: (_) => _newAiQuery(),
      ),
      KeyCommand(
        id: 'agent',
        label: 'Ask the agent…',
        description: 'Opens a chat with an AI agent that reads the schema, runs read-only queries and drives the app.',
        keys: const ['meta+shift+a'],
        enabled: connected,
        hiddenFrom: _peopleOnly,
        onRun: (_) => _openAgent(),
      ),
      KeyCommand(
        id: 'settings',
        label: 'Settings…',
        hiddenFrom: _peopleOnly,
        onRun: (_) => showAiSettingsDialog(appContext()),
      ),
    ]),
    menu(AppMenu.help.label, [
      KeyCommand(
        id: 'welcome',
        label: 'Welcome…',
        onRun: (_) => showWelcome(appContext()),
      ),
      KeyCommand(
        id: 'command_palette',
        label: 'Command palette…',
        description: 'Search every command by name.',
        hiddenFrom: const {KeySurface.palette, KeySurface.agents},
        onRun: (_) => keys.showPalette(),
      ),
      KeyCommand(
        id: 'shortcuts',
        label: 'Keyboard shortcuts…',
        hiddenFrom: const {KeySurface.agents},
        onRun: (_) => keys.showHelp(),
      ),
    ]),
    // Plugin-defined top-level menus appear after the built-ins.
    for (final label in commands.extraMenuLabels)
      KeyGroup(
        id: commandIdFor(label),
        label: label,
        inMenuBar: true,
        children: commands.commandsFor(label).skip(1).toList(),
      ),
  ];
}

/// `meta+<key>` (⌘ on macOS, Ctrl elsewhere), plus Ctrl on macOS too, for
/// the shortcuts that have always answered to both there.
List<String> _metaWithMacControl(String key) => [
  'meta+$key',
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) 'ctrl+$key',
];

String? get _activeConnectionId => ConnectionRegistry.instance.activeId;

void _newQuery() {
  final connId = _activeConnectionId;
  if (connId == null) return;
  AppState.instance.newQueryTab(connId);
}

void _newNavigator() {
  final connId = _activeConnectionId;
  if (connId == null) return;
  AppState.instance.openTab(NavigatorTab(connectionId: connId));
}

void _newLinked() {
  final connId = _activeConnectionId;
  if (connId == null) return;
  AppState.instance.openTab(LinkedTab(connectionId: connId));
}

void _openSchema() {
  final connId = _activeConnectionId;
  if (connId == null) return;
  final state = AppState.instance;
  // Focus the existing Schema tab for this connection if one is open;
  // otherwise create a fresh one. Schema view is connection-scoped and
  // having two side by side adds noise without value.
  for (final tab in state.tabs) {
    if (tab is SchemaTab && tab.connectionId == connId) {
      state.selectTab(tab.id);
      return;
    }
  }
  state.openTab(SchemaTab(connectionId: connId));
}

void _newAiQuery() {
  final connId = _activeConnectionId;
  if (connId == null) return;
  AppState.instance.newAiQueryTab(connId);
}

Future<void> _toggleReadOnly() async {
  final id = ConnectionRegistry.instance.activeId;
  if (id == null) return;
  await ConnectionRegistry.instance.setReadOnly(
    id,
    readOnly: !ConnectionRegistry.instance.isReadOnly,
  );
}

void _closeActiveTab() {
  final active = AppState.instance.active;
  if (active != null) AppState.instance.closeTab(active.id);
}

void _openAgent() {
  final connId = _activeConnectionId;
  if (connId == null) return;
  AppState.instance.openTab(AgentTab(connectionId: connId));
}

/// The agent-only `view.open_table`: opens (or focuses) the table its input
/// names. The model wrote the input, so it is checked here.
String _openTable(Map<String, Object?> input) {
  final connId = _activeConnectionId;
  final schema = input[_OpenTableArgs.schema];
  final table = input[_OpenTableArgs.table];
  if (connId == null) throw StateError('No connection is open.');
  if (schema is! String || table is! String || schema.isEmpty || table.isEmpty) {
    throw ArgumentError('Give "schema" and "table" as non-empty strings.');
  }
  AppState.instance.openOrFocusTable(
    connectionId: connId,
    schema: schema,
    table: table,
    estimatedRows: -1,
  );
  return 'Opened $schema.$table in a tab.';
}

void _findTable() {
  if (!AppState.instance.sidebarVisible) {
    AppState.instance.toggleSidebarVisible();
  }
  SidebarFocusController.instance.requestFilterFocus();
}

/// Shows the welcome dialog, remembers that it was seen so it stops
/// opening at startup, and starts the new-connection flow if the user
/// asked for it. Used at first launch and by Help ▸ Welcome….
Future<void> showWelcome(BuildContext context) async {
  final choice = await showWelcomeDialog(context);
  UiPrefs.instance.setWelcomeSeen();
  if (choice != WelcomeChoice.addConnection) return;
  if (!context.mounted) return;
  await _addConnection(context);
}

Future<void> _addConnection(BuildContext context) async {
  final profile = await showAddConnectionDialog(context);
  if (profile == null) return;
  if (!context.mounted) return;
  await ConnectionRegistry.instance.connectProfile(profile, context: context);
  AppState.instance.notifyChange();
}

/// Export the active connection as a portable, passphrase-encrypted
/// `.dbscopeconn` link. Requires an active profile with a stored password.
Future<void> _exportConnection(BuildContext context) async {
  final registry = ConnectionRegistry.instance;
  final messenger = ScaffoldMessenger.of(context);
  var profile = registry.profile;
  if (profile == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Select a connection to export first.')),
    );
    return;
  }
  // The active profile's password may be lazily loaded (kept out of the
  // in-memory profile until connect). Pull it from secure storage so the
  // exported link is self-contained.
  if (profile.password.isEmpty) {
    profile = await registry.profileWithPassword(profile.id) ?? profile;
  }
  if (!context.mounted) return;
  await ConnectionLinkFlow.exportProfile(context, profile);
}

/// Pick a SQLite file and connect to it directly. The resulting profile
/// is persisted (so it shows up in the connection list), with a name
/// derived from the file name; the user can rename or delete it later.
Future<void> _openSqliteFile(BuildContext context) async {
  final picked = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'SQLite',
        extensions: ['db', 'sqlite', 'sqlite3', 'db3'],
      ),
      XTypeGroup(label: 'All files'),
    ],
  );
  if (picked == null) return;
  if (!context.mounted) return;
  final path = picked.path;
  final sep = path.contains(r'\') ? r'\' : '/';
  final base = path.split(sep).last;
  final dot = base.lastIndexOf('.');
  final stem = dot <= 0 ? base : base.substring(0, dot);
  final profile = ConnectionProfile(
    kind: kSqliteKind,
    name: stem,
    database: stem,
    readOnly: false,
    extra: {'path': path},
  );
  await ConnectionRegistry.instance.connectProfile(profile, context: context);
  AppState.instance.notifyChange();
}
