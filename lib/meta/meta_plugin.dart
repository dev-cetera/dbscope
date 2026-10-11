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

    for (final c in [
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
    ]) {
      host.menus.register(c);
    }

    host.sidebarActions.registerProvider(_sidebarActions);
  }

  /// Table-scoped metadata actions plus "About this table…".
  static List<SidebarTableAction> _sidebarActions(
    SidebarTableActionContext ctx,
  ) {
    final snapshot = MetadataCache.instance.snapshotFor(ctx.connectionId);
    if (snapshot == null) return const [];
    final click = MetaClickContext(
      connectionId: ctx.connectionId,
      schema: ctx.schema,
      table: ctx.table,
    );
    final actions = snapshot.index.actionsForTable(
      ActionScope.table,
      ctx.schema,
      ctx.table,
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
          onSelected: (c) =>
              MetaActionRunner.run(c.buildContext, action, click),
        ),
      );
    }
    out.add(
      SidebarTableAction(
        id: 'meta:about-table',
        label: 'About this table…',
        icon: Icons.info_outline,
        startsGroup: true,
        onSelected: (c) => showAboutTableDialog(
          c.buildContext,
          connectionId: ctx.connectionId,
          schema: ctx.schema,
          table: ctx.table,
        ),
      ),
    );
    final canDescribe =
        snapshot.policy.can(Capability.manage) &&
        !ConnectionRegistry.instance.isReadOnlyFor(ctx.connectionId);
    if (canDescribe) {
      out.add(
        SidebarTableAction(
          id: 'meta:describe-table',
          label: 'Edit table description…',
          icon: Icons.edit_note,
          onSelected: (c) => showEditDescriptionDialog(
            c.buildContext,
            connectionId: ctx.connectionId,
            schema: ctx.schema,
            table: ctx.table,
            initial:
                snapshot.index
                    .describeTable(ctx.schema, ctx.table)
                    .description ??
                '',
          ),
        ),
      );
    }
    return out;
  }
}
