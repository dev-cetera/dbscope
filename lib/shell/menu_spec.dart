import 'package:flutter/widgets.dart';

/// Cross-platform menu spec, consumed by both the native macOS
/// `PlatformMenuBar` and the in-app fallback bar. One source of truth,
/// so adding a menu item is a single edit.
///
/// Named "Spec" (rather than the more natural "AppMenu") because the
/// shared `package:widgets` already owns `AppMenu`/`AppMenuItem` types
/// with a different shape (no submenus, string shortcuts).
class MenuSpec {
  final String label;
  final List<MenuItemSpec> items;
  const MenuSpec({required this.label, required this.items});
}

/// One entry in a menu. Either an action ([onSelected] set) or a
/// submenu ([children] set). A new visual group starts on any item
/// flagged [startsGroup].
class MenuItemSpec {
  final String label;
  final VoidCallback? onSelected;
  final SingleActivator? shortcut;
  final List<MenuItemSpec>? children;
  final bool startsGroup;

  const MenuItemSpec({
    required this.label,
    this.onSelected,
    this.shortcut,
    this.children,
    this.startsGroup = false,
  });

  bool get isSubmenu => children != null;
}

/// One plugin-contributed menu item. Resolved fresh on every menu
/// rebuild — the [build] callback receives the active `BuildContext`
/// and decides at click-time which action to dispatch. Items are
/// inserted at the end of the named menu, after the built-in items.
class MenuContribution {
  /// Target menu by label: 'File', 'View', 'Connection', 'AI', etc.
  /// New menu labels are added automatically if no built-in matches.
  final String menu;
  final MenuItemSpec Function(BuildContext context) build;
  final bool startsGroup;

  const MenuContribution({
    required this.menu,
    required this.build,
    this.startsGroup = true,
  });
}

/// Process-wide registry of menu contributions. The built-in menus
/// (File / View / Connection / AI) are always present; plugins append
/// to them or define new top-level menus by registering items here.
class MenuContributionRegistry {
  MenuContributionRegistry._();
  static final MenuContributionRegistry instance = MenuContributionRegistry._();

  final List<MenuContribution> _contributions = [];

  void register(MenuContribution c) => _contributions.add(c);

  List<MenuContribution> forMenu(String menu) =>
      _contributions.where((c) => c.menu == menu).toList(growable: false);

  Iterable<String> get extraMenuLabels {
    final builtins = {'File', 'View', 'Connection', 'AI'};
    final seen = <String>{};
    for (final c in _contributions) {
      if (!builtins.contains(c.menu)) seen.add(c.menu);
    }
    return seen;
  }
}
