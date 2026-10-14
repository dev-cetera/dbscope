import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

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
import 'env_dialog.dart';
import 'menu_spec.dart';
import 'theme_registry.dart';
import 'window_actions.dart';

// One AppMenuBar widget; two renderers. The data lives in
// `_buildMenus(context)` and is consumed by either the native macOS
// `PlatformMenuBar` or the in-app `_FallbackMenuBar`. There is no
// duplication between the two paths.

class AppMenuBar extends StatelessWidget {
  const AppMenuBar({super.key, required this.child});
  final Widget child;

  bool get _useNativeMacMenu =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    final menus = _MenuActions(context).buildMenus();
    if (_useNativeMacMenu) {
      return PlatformMenuBar(
        menus: [for (final menu in menus) _toPlatformMenu(menu)],
        child: child,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FallbackMenuBar(menus: menus),
        Expanded(child: child),
      ],
    );
  }
}

// Action bundle shared by both renderers. All callbacks resolve against
// the live AppState / ConnectionRegistry singletons at click time, so
// the menu data itself can be rebuilt per frame without losing wiring.
class _MenuActions {
  _MenuActions(this.context);
  final BuildContext context;

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

  List<MenuItemSpec> _contributionsFor(String menu) {
    final regs = MenuContributionRegistry.instance.forMenu(menu);
    return [
      for (final contribution in regs)
        MenuItemSpec(
          label: contribution.build(context).label,
          onSelected: contribution.build(context).onSelected,
          shortcut: contribution.build(context).shortcut,
          children: contribution.build(context).children,
          startsGroup: contribution.startsGroup,
        ),
    ];
  }

  List<MenuSpec> buildMenus() {
    final state = AppState.instance;
    final registry = ConnectionRegistry.instance;
    final menus = [
      MenuSpec(
        label: 'File',
        items: [
          MenuItemSpec(
            label: 'New query',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyT,
              meta: true,
            ),
            onSelected: _newQuery,
          ),
          MenuItemSpec(
            label: 'New navigator',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyT,
              meta: true,
              shift: true,
            ),
            onSelected: _newNavigator,
          ),
          MenuItemSpec(label: 'New linked view', onSelected: _newLinked),
          const MenuItemSpec(
            label: 'New window',
            shortcut: SingleActivator(
              LogicalKeyboardKey.keyN,
              meta: true,
              shift: true,
            ),
            onSelected: WindowActions.spawnWindow,
          ),
          MenuItemSpec(
            label: 'New connection…',
            onSelected: () => _addConnection(context),
          ),
          MenuItemSpec(
            label: 'Import connection link…',
            onSelected: () => ConnectionLinkFlow.importAndConnect(context),
          ),
          MenuItemSpec(
            label: 'Export connection link…',
            onSelected: () => _exportConnection(context),
          ),
          MenuItemSpec(
            label: 'Open .db file…',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyO,
              meta: true,
            ),
            onSelected: () => _openSqliteFile(context),
          ),
          MenuItemSpec(
            label: 'Export schema as DBML…',
            onSelected: () => DbmlExportFlow.run(context),
          ),
          MenuItemSpec(
            label: 'Environment…',
            startsGroup: true,
            onSelected: () => showEnvDialog(context),
          ),
          MenuItemSpec(
            label: 'Close tab',
            startsGroup: true,
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyW,
              meta: true,
            ),
            onSelected: _closeActiveTab,
          ),
          ..._contributionsFor('File'),
        ],
      ),
      MenuSpec(
        label: 'View',
        items: [
          MenuItemSpec(
            label: 'Schema',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyD,
              meta: true,
            ),
            onSelected: _openSchema,
          ),
          MenuItemSpec(label: 'New navigator', onSelected: _newNavigator),
          MenuItemSpec(label: 'New linked view', onSelected: _newLinked),
          MenuItemSpec(
            label: state.sidebarVisible ? 'Hide sidebar' : 'Show sidebar',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyB,
              meta: true,
            ),
            onSelected: state.toggleSidebarVisible,
          ),
          MenuItemSpec(
            label: 'Toggle sidebar side',
            onSelected: state.toggleSidebar,
          ),
          MenuItemSpec(
            label: 'Theme',
            startsGroup: true,
            children: [
              for (final theme in ThemeRegistry.instance.all)
                MenuItemSpec(
                  label:
                      '${state.themeId == theme.id ? '● ' : ' '}${theme.label}',
                  onSelected: () => state.setThemeId(theme.id),
                ),
            ],
          ),
          ..._contributionsFor('View'),
        ],
      ),
      MenuSpec(
        label: 'Connection',
        items: [
          MenuItemSpec(
            label: 'Add…',
            onSelected: () => _addConnection(context),
          ),
          MenuItemSpec(
            label: 'Export as connection link…',
            onSelected: () => _exportConnection(context),
          ),
          MenuItemSpec(label: 'Toggle read-only', onSelected: _toggleReadOnly),
          MenuItemSpec(
            label: 'Disconnect',
            onSelected: () async => registry.disconnect(),
          ),
          ..._contributionsFor('Connection'),
        ],
      ),
      MenuSpec(
        label: 'AI',
        items: [
          MenuItemSpec(
            label: 'New AI query',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyT,
              meta: true,
              alt: true,
            ),
            onSelected: _newAiQuery,
          ),
          MenuItemSpec(
            label: 'Settings…',
            onSelected: () => showAiSettingsDialog(context),
          ),
          ..._contributionsFor('AI'),
        ],
      ),
    ];
    // Plugin-defined top-level menus appear after the built-ins.
    for (final label in MenuContributionRegistry.instance.extraMenuLabels) {
      menus.add(MenuSpec(label: label, items: _contributionsFor(label)));
    }
    return menus;
  }
}

// Native macOS renderer.

PlatformMenu _toPlatformMenu(MenuSpec menu) {
  return PlatformMenu(
    label: menu.label,
    menus: _itemsToPlatform(menu.items),
  );
}

List<PlatformMenuItem> _itemsToPlatform(List<MenuItemSpec> items) {
  // Group runs of items: a new group starts on each item flagged
  // `startsGroup`. PlatformMenuItemGroup is the macOS way to render a
  // divider — we don't get to draw one ourselves.
  final out = <PlatformMenuItem>[];
  final current = <PlatformMenuItem>[];
  void flush() {
    if (current.isEmpty) return;
    if (out.isEmpty) {
      out.addAll(current);
    } else {
      out.add(PlatformMenuItemGroup(members: List.of(current)));
    }
    current.clear();
  }

  var first = true;
  for (final item in items) {
    if (item.startsGroup && !first) {
      out.addAll(current);
      current.clear();
      // Mark next batch as a separate group via PlatformMenuItemGroup.
      out.add(PlatformMenuItemGroup(members: [_itemToPlatform(item)]));
      continue;
    }
    current.add(_itemToPlatform(item));
    first = false;
  }
  flush();
  return out;
}

PlatformMenuItem _itemToPlatform(MenuItemSpec item) {
  if (item.isSubmenu) {
    return PlatformMenu(
      label: item.label,
      menus: _itemsToPlatform(item.children!),
    );
  }
  return PlatformMenuItem(
    label: item.label,
    shortcut: item.shortcut,
    onSelected: item.onSelected,
  );
}

// In-app fallback renderer (non-mac and web).

class _FallbackMenuBar extends StatelessWidget {
  const _FallbackMenuBar({required this.menus});
  final List<MenuSpec> menus;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      color: palette.surfaceRaised,
      child: SizedBox(
        height: 28.0,
        child: Row(
          children: [
            for (final menu in menus) _MenuButton(menu: menu),
          ],
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.menu});
  final MenuSpec menu;

  Future<void> _show(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final flattened = _flattenForPopup(menu.items);
    final picked = await showMenu<MenuItemSpec>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: [
        for (final e in flattened)
          PopupMenuItem<MenuItemSpec>(
            value: e,
            height: 28.0,
            child: Text(e.label),
          ),
      ],
    );
    picked?.onSelected?.call();
  }

  /// The fallback PopupMenu can't render submenus inline, so we flatten:
  /// each submenu's label becomes a header (disabled, surfaced as the
  /// parent label) and its children render below with an "indent" prefix.
  static List<MenuItemSpec> _flattenForPopup(List<MenuItemSpec> items) {
    final out = <MenuItemSpec>[];
    for (final item in items) {
      if (item.isSubmenu) {
        for (final child in item.children!) {
          out.add(
            MenuItemSpec(
              label: '${item.label}: ${child.label}',
              onSelected: child.onSelected,
            ),
          );
        }
      } else {
        out.add(item);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Builder(
      builder: (builderContext) => InkWell(
        onTapDown: (details) => _show(builderContext, details.globalPosition),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          alignment: Alignment.center,
          child: Text(
            menu.label,
            style: TextStyle(
              color: palette.text,
              fontSize: palette.bodyFontSize,
              fontFamily: palette.uiFontFamily,
            ),
          ),
        ),
      ),
    );
  }
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
