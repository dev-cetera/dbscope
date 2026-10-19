import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../catalog/schema_catalog.dart';
import '../connection/profile.dart';
import '../connection/registry.dart';
import '../jobs/copy_table_dialog.dart';
import '../linked/linked_tab.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../navigator/navigator_tab.dart';
import '../rpc/scope.dart';
import '../rpc/services/job_client.dart';
import 'app_state.dart';
import 'sidebar_table_actions.dart';
import 'soft_delete_dialog.dart';

// Built-in sidebar table-row actions. Registered once from main.dart.
// Plugins / features add their own with [SidebarTableActionRegistry.register].

void registerDefaultSidebarTableActions() {
  final registry = SidebarTableActionRegistry.instance;
  registry.register(_openAsTable);
  registry.register(_openAsNavigator);
  registry.register(_openAsLinked);
  registry.register(_copyName);
  registry.register(_copyQualified);
  registry.register(_configureSoftDelete);
  registry.register(_copyToAnother);
}

final _openAsTable = SidebarTableAction(
  id: 'table',
  label: 'Open as Table',
  icon: Icons.table_chart_outlined,
  onSelected: (actionContext) async {
    AppState.instance.openOrFocusTable(
      connectionId: actionContext.connectionId,
      schema: actionContext.schema,
      table: actionContext.table,
      estimatedRows: actionContext.estimatedRows,
    );
  },
);

final _openAsNavigator = SidebarTableAction(
  id: 'navigator',
  label: 'Open as Navigator',
  icon: Icons.view_column_outlined,
  onSelected: (actionContext) async {
    final tab = NavigatorTab(connectionId: actionContext.connectionId);
    tab.steps.add(
      RowListStep(schema: actionContext.schema, table: actionContext.table),
    );
    AppState.instance.openTab(tab);
  },
);

final _openAsLinked = SidebarTableAction(
  id: 'linked',
  label: 'Open as Linked',
  icon: Icons.hub_outlined,
  onSelected: (actionContext) async {
    AppState.instance.openTab(
      LinkedTab(
        connectionId: actionContext.connectionId,
        seedSchema: actionContext.schema,
        seedTable: actionContext.table,
      ),
    );
  },
);

final _copyName = SidebarTableAction(
  id: 'copyname',
  label: 'Copy table name',
  icon: Icons.copy,
  startsGroup: true,
  onSelected: (actionContext) async {
    await Clipboard.setData(ClipboardData(text: actionContext.table));
    if (actionContext.buildContext.mounted) {
      showToast(actionContext.buildContext, 'Copied "${actionContext.table}"');
    }
  },
);

final _copyQualified = SidebarTableAction(
  id: 'copyqual',
  label: 'Copy schema.table',
  icon: Icons.copy_all,
  onSelected: (actionContext) async {
    final qualifiedName = '${actionContext.schema}.${actionContext.table}';
    await Clipboard.setData(ClipboardData(text: qualifiedName));
    if (actionContext.buildContext.mounted) {
      showToast(actionContext.buildContext, 'Copied "$qualifiedName"');
    }
  },
);

// Soft-delete and copy-to-DB rewrite rows; both should hide on
// read-only / dml-incapable backends so the menu doesn't promise an
// action that's going to fail when invoked.
bool _canCopyOut(SidebarTableActionContext actionContext) {
  final snapshot = MetadataCache.instance.snapshotFor(
    actionContext.connectionId,
  );
  final policy = snapshot?.policy;
  if (policy == null || !policy.active) return true;
  if (!policy.can(Capability.export)) return false;
  return policy.forTable(actionContext.schema, actionContext.table).canSeeValues;
}

bool _backendSupportsDml(SidebarTableActionContext actionContext) {
  final executor = ConnectionRegistry.instance.connectionFor(
    actionContext.connectionId,
  );
  if (executor == null) return false;
  return executor.capabilities.dml;
}

final _configureSoftDelete = SidebarTableAction(
  id: 'softdel',
  label: 'Configure soft-delete column…',
  icon: Icons.auto_delete_outlined,
  startsGroup: true,
  visibleWhen: _backendSupportsDml,
  onSelected: (actionContext) async {
    final registry = ConnectionRegistry.instance;
    final profile = registry.profileById(actionContext.connectionId);
    if (profile == null) return;
    final existing = profile
        .overridesFor(actionContext.schema, actionContext.table)
        .softDeleteColumn;
    final result = await showSoftDeleteDialog(
      actionContext.buildContext,
      schema: actionContext.schema,
      table: actionContext.table,
      initialColumn: existing,
    );
    if (result == null || !actionContext.buildContext.mounted) return;
    final overrides = result.clear ? null : TableOverrides(softDeleteColumn: result.column);
    await registry.setTableOverride(
      profile.id,
      actionContext.schema,
      actionContext.table,
      overrides,
    );
    if (!actionContext.buildContext.mounted) return;
    showToast(
      actionContext.buildContext,
      result.clear
          ? 'Soft-delete cleared for ${actionContext.schema}.${actionContext.table}'
          : 'Soft-delete column set to "${result.column}" for ${actionContext.schema}.${actionContext.table}',
    );
  },
);

final _copyToAnother = SidebarTableAction(
  id: 'copy',
  label: 'Copy to another DB…',
  icon: Icons.cloud_sync_outlined,
  startsGroup: true,
  // Copying runs as a server-side job that never passes through the
  // grid's column access, so it needs the export capability and full read
  // access to the table (no masked or hidden columns) up front.
  visibleWhen: _canCopyOut,
  onSelected: (actionContext) async {
    final source = ConnectionRegistry.instance.connectionFor(
      actionContext.connectionId,
    );
    if (source != null && MetadataCache.instance.policyForExecutor(source).active) {
      final visible = await SchemaCatalog(source).listColumns(
        actionContext.schema,
        actionContext.table,
      );
      final all = await SchemaCatalog.unfiltered(source).listColumns(
        actionContext.schema,
        actionContext.table,
      );
      final restricted =
          visible.length < all.length ||
          visible.any(
            (column) => !column.accessLevel.atLeast(AccessLevel.read),
          );
      if (restricted) {
        if (!actionContext.buildContext.mounted) return;
        showToast(
          actionContext.buildContext,
          'Some columns of ${actionContext.table} are hidden or masked for '
          'you, so it cannot be copied out.',
        );
        return;
      }
      if (!actionContext.buildContext.mounted) return;
    }
    final profiles = ConnectionRegistry.instance.profiles;
    if (profiles.length < 2) {
      showToast(actionContext.buildContext, 'Add a second connection first.');
      return;
    }
    final result = await showDialog<CopyTableTarget>(
      context: actionContext.buildContext,
      builder: (_) => CopyTableDialog(
        sourceConnectionId: actionContext.connectionId,
        sourceSchema: actionContext.schema,
        sourceTable: actionContext.table,
        profiles: profiles,
      ),
    );
    if (result == null || !actionContext.buildContext.mounted) return;
    final client = BackendScope.of(actionContext.buildContext);
    await ConnectionRegistry.instance.setActive(
      result.target.id,
      context: actionContext.buildContext,
    );
    if (!actionContext.buildContext.mounted) return;
    await ConnectionRegistry.instance.connectActive(
      context: actionContext.buildContext,
    );
    if (!actionContext.buildContext.mounted) return;
    // The job writes into the target, so the target's own access control
    // must allow full access to that table (it runs server-side, past the
    // grid's gates).
    final target = ConnectionRegistry.instance.connectionFor(result.target.id);
    if (target != null) {
      final targetAccess = MetadataCache.instance
          .policyForExecutor(target)
          .forTable(result.targetSchema, result.targetTable);
      if (!targetAccess.level.atLeast(AccessLevel.full)) {
        showToast(
          actionContext.buildContext,
          'Your access to ${result.targetSchema}.${result.targetTable} on '
          '${result.target.name} is ${targetAccess.level.name}; copying into '
          'it needs full.',
        );
        return;
      }
    }
    final jobs = JobServiceClient(client);
    try {
      final submitted = await jobs.submit('copy_table', {
        'sourceConnectionId': actionContext.connectionId,
        'sourceSchema': actionContext.schema,
        'sourceTable': actionContext.table,
        'targetConnectionId': result.target.id,
        'targetSchema': result.targetSchema,
        'targetTable': result.targetTable,
        'mode': result.mode,
      });
      AppState.instance.openTab(
        JobTab(
          jobId: submitted.id,
          kind: 'copy_table',
          summary:
              '${actionContext.schema}.${actionContext.table} → ${result.target.name}/${result.targetSchema}.${result.targetTable}',
        ),
      );
    } catch (e) {
      if (!actionContext.buildContext.mounted) return;
      showToast(actionContext.buildContext, 'Job submit failed: $e');
    }
  },
);
