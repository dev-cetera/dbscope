// Registers the schema-metadata features through the same DbscopePlugin
// shape as every other built-in: the named-query and dashboard tab kinds,
// the Metadata menu, and the metadata entries of the sidebar's table menu.

import 'package:flutter/material.dart';

import '../connection/registry.dart';
import '../plugins/dbscope_plugin.dart';
import '../shell/menu_spec.dart';
import '../shell/sidebar_table_actions.dart';
import 'dashboard/dashboard_tab.dart';
import 'meta_cache.dart';
import 'meta_models.dart';
import 'named_query/named_query_tab_kind.dart';
import 'ui/action_runner.dart';
import 'ui/meta_admin.dart';
import 'ui/meta_dialogs.dart';
import 'ui/meta_menu.dart';

class MetaPlugin extends DbscopePlugin {
  @override
  String get id => 'meta';

  @override
  String get label => 'Schema metadata';

  @override
  void register(DbscopeHost host) {
    host.tabs
      ..register(namedQueryTabKind)
      ..register(dashboardTabKind);

    MenuContribution item(
      String label,
      void Function(BuildContext context) run, {
      bool startsGroup = false,
    }) => MenuContribution(
      menu: 'Metadata',
      startsGroup: startsGroup,
      build: (context) =>
          MenuItemSpec(label: label, onSelected: () => run(context)),
    );

    [
      item('Reload metadata', reloadActiveMetadata),
      item('Problems…', showMetadataProblems),
      item('Settings…', showMetadataSettings),
      item('Your access…', showEffectiveAccess, startsGroup: true),
      item('View as… / stop viewing as', showViewAs),
      item('Run checks…', showChecks, startsGroup: true),
      item('Actions…', showGlobalActions),
      item('Trust metadata SQL…', trustMetadataSql, startsGroup: true),
      item('Revoke trust', revokeMetadataTrust),
      item(
        'Initialize metadata tables…',
        showInitializeTables,
        startsGroup: true,
      ),
      item('Import metadata file into tables…', importMetadataFile),
      item('Export metadata to file…', exportMetadataFile),
      item('Generate enforcement SQL…', showEnforcementSql),
    ].forEach(host.menus.register);

    host.sidebarActions.registerProvider(_sidebarActions);
  }

  /// Table-scoped metadata actions plus "About this table…".
  static List<SidebarTableAction> _sidebarActions(
    SidebarTableActionContext actionContext,
  ) {
    final snapshot = MetadataCache.instance.snapshotFor(
      actionContext.connectionId,
    );
    if (snapshot == null) return const [];
    final click = MetaClickContext(
      connectionId: actionContext.connectionId,
      schema: actionContext.schema,
      table: actionContext.table,
    );
    final actions = snapshot.index.actionsForTable(
      ActionScope.table,
      actionContext.schema,
      actionContext.table,
    );
    final out = <SidebarTableAction>[];
    for (var i = 0; i < actions.length; i++) {
      final action = actions[i];
      final reason = actionUnavailableReason(action, click);
      out.add(
        SidebarTableAction(
          id: 'meta:${action.id}',
          label: reason == null ? action.label : '${action.label} — $reason',
          icon: Icons.bolt_outlined,
          startsGroup: i == 0,
          onSelected: (actionContext) =>
              MetaActionRunner.run(actionContext.buildContext, action, click),
        ),
      );
    }
    out.add(
      SidebarTableAction(
        id: 'meta:about-table',
        label: 'About this table…',
        icon: Icons.info_outline,
        startsGroup: true,
        onSelected: (actionContext) => showAboutTableDialog(
          actionContext.buildContext,
          connectionId: actionContext.connectionId,
          schema: actionContext.schema,
          table: actionContext.table,
        ),
      ),
    );
    final canDescribe =
        snapshot.policy.can(Capability.manage) &&
        !ConnectionRegistry.instance.isReadOnlyFor(actionContext.connectionId);
    if (canDescribe) {
      out.add(
        SidebarTableAction(
          id: 'meta:describe-table',
          label: 'Edit table description…',
          icon: Icons.edit_note,
          onSelected: (actionContext) => showEditDescriptionDialog(
            actionContext.buildContext,
            connectionId: actionContext.connectionId,
            schema: actionContext.schema,
            table: actionContext.table,
            initial:
                snapshot.index
                    .describeTable(actionContext.schema, actionContext.table)
                    .description ??
                '',
          ),
        ),
      );
    }
    return out;
  }
}
