import 'package:flutter/material.dart';

/// Context passed to a sidebar table action when the user triggers it
/// from a table row's right-click / long-press menu.
class SidebarTableActionContext {
  const SidebarTableActionContext({
    required this.buildContext,
    required this.connectionId,
    required this.schema,
    required this.table,
    required this.estimatedRows,
  });
  final BuildContext buildContext;
  final String connectionId;
  final String schema;
  final String table;
  final int estimatedRows;
}

/// One entry in the table-row context menu. Built-in actions ("Open as
/// Table", "Open as Navigator", etc.) live in `sidebar_table_actions_default.dart`;
/// plugins / features can register their own.
class SidebarTableAction {
  const SidebarTableAction({
    required this.id,
    required this.label,
    required this.onSelected,
    this.icon,
    this.startsGroup = false,
    this.visibleWhen,
  });

  /// Stable id, used as the popup-menu return value.
  final String id;
  final String label;
  final IconData? icon;

  /// When true, render a divider before this action in the menu. The
  /// first action's divider flag is ignored.
  final bool startsGroup;

  /// Predicate gating visibility. Most actions return true unconditionally;
  /// plugins may want to check connection kind, schema, etc. Optional.
  final bool Function(SidebarTableActionContext actionContext)? visibleWhen;

  /// What to do when the user picks the action.
  final Future<void> Function(SidebarTableActionContext actionContext)
  onSelected;
}

/// Process-wide registry. Built-ins register from `main.dart`; plugins
/// register from their own `register*()` entry points.
class SidebarTableActionRegistry {
  SidebarTableActionRegistry._();
  static final instance = SidebarTableActionRegistry._();

  final List<SidebarTableAction> _actions = [];

  /// Providers compute extra actions per table at menu time (e.g. schema
  /// metadata actions, which depend on the connection and table).
  final List<
    List<SidebarTableAction> Function(SidebarTableActionContext actionContext)
  >
  _providers = [];

  void registerProvider(
    List<SidebarTableAction> Function(SidebarTableActionContext actionContext)
    provider,
  ) {
    _providers.add(provider);
  }

  void register(SidebarTableAction action) {
    _actions.removeWhere((existing) => existing.id == action.id);
    _actions.add(action);
  }

  /// All actions, in registration order, filtered by [SidebarTableAction.visibleWhen].
  List<SidebarTableAction> visibleFor(SidebarTableActionContext actionContext) {
    return [
      ..._actions.where(
        (action) => action.visibleWhen?.call(actionContext) ?? true,
      ),
      for (final provider in _providers) ...provider(actionContext),
    ];
  }
}
