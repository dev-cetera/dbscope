import 'package:flutter/material.dart';

/// Context passed to a sidebar table action when the user triggers it
/// from a table row's right-click / long-press menu.
class SidebarTableActionContext {
  final BuildContext buildContext;
  final String connectionId;
  final String schema;
  final String table;
  final int estimatedRows;

  const SidebarTableActionContext({
    required this.buildContext,
    required this.connectionId,
    required this.schema,
    required this.table,
    required this.estimatedRows,
  });
}

/// One entry in the table-row context menu. Built-in actions ("Open as
/// Table", "Open as Navigator", etc.) live in `sidebar_table_actions_default.dart`;
/// plugins / features can register their own.
class SidebarTableAction {
  /// Stable id, used as the popup-menu return value.
  final String id;
  final String label;
  final IconData? icon;

  /// When true, render a divider before this action in the menu. The
  /// first action's divider flag is ignored.
  final bool startsGroup;

  /// Predicate gating visibility. Most actions return true unconditionally;
  /// plugins may want to check connection kind, schema, etc. Optional.
  final bool Function(SidebarTableActionContext ctx)? visibleWhen;

  /// What to do when the user picks the action.
  final Future<void> Function(SidebarTableActionContext ctx) onSelected;

  const SidebarTableAction({
    required this.id,
    required this.label,
    required this.onSelected,
    this.icon,
    this.startsGroup = false,
    this.visibleWhen,
  });
}

/// Process-wide registry. Built-ins register from `main.dart`; plugins
/// register from their own `register*()` entry points.
class SidebarTableActionRegistry {
  SidebarTableActionRegistry._();
  static final SidebarTableActionRegistry instance =
      SidebarTableActionRegistry._();

  final List<SidebarTableAction> _actions = [];

  void register(SidebarTableAction action) {
    _actions.removeWhere((a) => a.id == action.id);
    _actions.add(action);
  }

  /// All actions, in registration order, filtered by [visibleWhen].
  List<SidebarTableAction> visibleFor(SidebarTableActionContext ctx) {
    return _actions
        .where((a) => a.visibleWhen?.call(ctx) ?? true)
        .toList(growable: false);
  }
}
