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
  final r = SidebarTableActionRegistry.instance;
  r.register(_openAsTable);
  r.register(_openAsNavigator);
  r.register(_openAsLinked);
  r.register(_copyName);
  r.register(_copyQualified);
  r.register(_configureSoftDelete);
  r.register(_copyToAnother);
}

final _openAsTable = SidebarTableAction(
  id: 'table',
  label: 'Open as Table',
  icon: Icons.table_chart_outlined,
  onSelected: (ctx) async {
    AppState.instance.openOrFocusTable(
      connectionId: ctx.connectionId,
      schema: ctx.schema,
      table: ctx.table,
      estimatedRows: ctx.estimatedRows,
    );
  },
);

final _openAsNavigator = SidebarTableAction(
  id: 'navigator',
  label: 'Open as Navigator',
  icon: Icons.view_column_outlined,
  onSelected: (ctx) async {
    final tab = NavigatorTab(connectionId: ctx.connectionId);
    tab.steps.add(RowListStep(schema: ctx.schema, table: ctx.table));
    AppState.instance.openTab(tab);
  },
);

final _openAsLinked = SidebarTableAction(
  id: 'linked',
  label: 'Open as Linked',
  icon: Icons.hub_outlined,
  onSelected: (ctx) async {
    AppState.instance.openTab(
      LinkedTab(
        connectionId: ctx.connectionId,
        seedSchema: ctx.schema,
        seedTable: ctx.table,
      ),
    );
  },
);

final _copyName = SidebarTableAction(
  id: 'copyname',
  label: 'Copy table name',
  icon: Icons.copy,
  startsGroup: true,
  onSelected: (ctx) async {
    await Clipboard.setData(ClipboardData(text: ctx.table));
    if (ctx.buildContext.mounted) {
      showToast(ctx.buildContext, 'Copied "${ctx.table}"');
    }
  },
);

final _copyQualified = SidebarTableAction(
  id: 'copyqual',
  label: 'Copy schema.table',
  icon: Icons.copy_all,
  onSelected: (ctx) async {
    final q = '${ctx.schema}.${ctx.table}';
    await Clipboard.setData(ClipboardData(text: q));
    if (ctx.buildContext.mounted) showToast(ctx.buildContext, 'Copied "$q"');
  },
);

// Soft-delete and copy-to-DB rewrite rows; both should hide on
// read-only / dml-incapable backends so the menu doesn't promise an
// action that's going to fail when invoked.
bool _canCopyOut(SidebarTableActionContext ctx) {
  final snapshot = MetadataCache.instance.snapshotFor(ctx.connectionId);
  final policy = snapshot?.policy;
  if (policy == null || !policy.active) return true;
  if (!policy.can(Capability.export)) return false;
  return policy.forTable(ctx.schema, ctx.table).canSeeValues;
}

bool _backendSupportsDml(SidebarTableActionContext ctx) {
  final conn = ConnectionRegistry.instance.connectionFor(ctx.connectionId);
  if (conn == null) return false;
  return conn.capabilities.dml;
}

final _configureSoftDelete = SidebarTableAction(
  id: 'softdel',
  label: 'Configure soft-delete column…',
  icon: Icons.auto_delete_outlined,
  startsGroup: true,
  visibleWhen: _backendSupportsDml,
  onSelected: (ctx) async {
    final registry = ConnectionRegistry.instance;
    final profile = registry.profileById(ctx.connectionId);
    if (profile == null) return;
    final existing = profile
        .overridesFor(ctx.schema, ctx.table)
        .softDeleteColumn;
    final result = await showSoftDeleteDialog(
      ctx.buildContext,
      schema: ctx.schema,
      table: ctx.table,
      initialColumn: existing,
    );
    if (result == null || !ctx.buildContext.mounted) return;
    final overrides = result.clear
        ? null
        : TableOverrides(softDeleteColumn: result.column);
    await registry.setTableOverride(
      profile.id,
      ctx.schema,
      ctx.table,
      overrides,
    );
    if (!ctx.buildContext.mounted) return;
    showToast(
      ctx.buildContext,
      result.clear
          ? 'Soft-delete cleared for ${ctx.schema}.${ctx.table}'
          : 'Soft-delete column set to "${result.column}" for ${ctx.schema}.${ctx.table}',
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
  onSelected: (ctx) async {
    final source = ConnectionRegistry.instance.connectionFor(ctx.connectionId);
    if (source != null &&
        MetadataCache.instance.policyForExecutor(source).active) {
      final visible = await SchemaCatalog(source).listColumns(
        ctx.schema,
        ctx.table,
      );
      final all = await SchemaCatalog.unfiltered(source).listColumns(
        ctx.schema,
        ctx.table,
      );
      final restricted =
          visible.length < all.length ||
          visible.any((c) => !c.accessLevel.atLeast(AccessLevel.read));
      if (restricted) {
        if (!ctx.buildContext.mounted) return;
        showToast(
          ctx.buildContext,
          'Some columns of ${ctx.table} are hidden or masked for you, so it '
          'cannot be copied out.',
        );
        return;
      }
      if (!ctx.buildContext.mounted) return;
    }
    final profiles = ConnectionRegistry.instance.profiles;
    if (profiles.length < 2) {
      showToast(ctx.buildContext, 'Add a second connection first.');
      return;
    }
    final result = await showDialog<CopyTableTarget>(
      context: ctx.buildContext,
      builder: (_) => CopyTableDialog(
        sourceConnectionId: ctx.connectionId,
        sourceSchema: ctx.schema,
        sourceTable: ctx.table,
        profiles: profiles,
      ),
    );
    if (result == null || !ctx.buildContext.mounted) return;
    final client = BackendScope.of(ctx.buildContext);
    await ConnectionRegistry.instance.setActive(
      result.target.id,
      context: ctx.buildContext,
    );
    if (!ctx.buildContext.mounted) return;
    await ConnectionRegistry.instance.connectActive(context: ctx.buildContext);
    if (!ctx.buildContext.mounted) return;
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
          ctx.buildContext,
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
        'sourceConnectionId': ctx.connectionId,
        'sourceSchema': ctx.schema,
        'sourceTable': ctx.table,
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
              '${ctx.schema}.${ctx.table} → ${result.target.name}/${result.targetSchema}.${result.targetTable}',
        ),
      );
    } catch (e) {
      if (!ctx.buildContext.mounted) return;
      showToast(ctx.buildContext, 'Job submit failed: $e');
    }
  },
);
