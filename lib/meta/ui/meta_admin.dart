// The Metadata menu's dialogs: problems, effective access, View as…,
// checks, settings, initialise tables, import/export, enforcement SQL,
// global actions.

import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../../catalog/schema_catalog.dart';
import '../../connection/registry.dart';
import '../../shell/app_state.dart';
import '../../util/pg_errors.dart';
import '../../util/portable_io.dart';
import '../../util/sql_quote.dart';
import '../enforcement_sql.dart';
import '../meta_cache.dart';
import '../meta_models.dart';
import '../meta_settings.dart';
import '../meta_sources.dart';
import '../meta_writer.dart';
import '../named_query/named_query_tab.dart';
import '../read_only_exec.dart';
import 'action_runner.dart';
import 'action_trust.dart';
import 'meta_dialogs.dart';
import 'meta_menu.dart';

const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

/// The enforcement dialog lists at most this many differences, so a badly
/// drifted database cannot flood the dialog.
const _kMaxDriftLinesShown = 200;

/// The active connection's id and snapshot, or null with a toast.
({String id, MetaSnapshot snapshot})? _active(BuildContext context) {
  final id = ConnectionRegistry.instance.activeId;
  final snapshot = MetadataCache.instance.snapshotFor(id);
  if (id == null || snapshot == null || ConnectionRegistry.instance.connectionFor(id) == null) {
    showToast(context, 'Connect to a database first.');
    return null;
  }
  return (id: id, snapshot: snapshot);
}

bool _requireManage(BuildContext context, MetaSnapshot snapshot) {
  if (snapshot.policy.can(Capability.manage)) return true;
  showToast(context, 'This needs a role with the manage capability.');
  return false;
}

Future<void> reloadActiveMetadata(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  await ConnectionRegistry.instance.reloadMetadata(active.id);
  if (!context.mounted) return;
  final problems = MetadataCache.instance.snapshotFor(active.id)?.problems;
  showToast(
    context,
    problems == null || problems.isEmpty
        ? 'Metadata reloaded.'
        : 'Metadata reloaded with ${problems.length} problem(s).',
  );
}

Future<void> showMetadataProblems(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final snapshot = active.snapshot;
  final problems = snapshot.problems;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AppFormDialog(
      title: 'Metadata problems',
      width: 640.0,
      height: 480.0,
      submitLabel: null,
      cancelLabel: 'Close',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sources: tables ${snapshot.tablesOutcome.name}'
            '${snapshot.settings.sidecarPath == null ? '' : ' · file ${snapshot.settings.sidecarPath}'}'
            ' · ${snapshot.index.document.rows.length} rows, '
            '${snapshot.index.document.grants.length} grants',
            style: Theme.of(dialogContext).textTheme.bodySmall,
          ),
          const SizedBox(height: 12.0),
          if (problems.isEmpty) const Text('No problems.'),
          for (final problem in problems)
            Padding(
              padding: const EdgeInsets.only(bottom: 6.0),
              child: SelectableText(problem.toString(), style: _mono),
            ),
        ],
      ),
    ),
  );
}

Future<void> showEffectiveAccess(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final executor = ConnectionRegistry.instance.connectionFor(active.id)!;
  final snapshot = active.snapshot;
  final policy = snapshot.policy;
  final rows = <(String, String, String, String)>[];
  if (policy.active) {
    final catalog = SchemaCatalog.unfiltered(executor);
    try {
      for (final schema in await catalog.listSchemas()) {
        if (schema.isSystem) continue;
        for (final table in await catalog.listTables(schema.name)) {
          final decision = policy.forTable(table.schema, table.name);
          rows.add((
            table.schema,
            table.name,
            decision.level.name,
            decision.reason,
          ));
        }
      }
    } catch (e) {
      if (context.mounted) showToast(context, classify(e).message);
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AppFormDialog(
        title: 'Your access on this connection',
        width: 720.0,
        height: 560.0,
        submitLabel: null,
        cancelLabel: 'Close',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!policy.active)
              const Text(
                'No access control on this connection: everything is full, '
                'every capability is on.',
              )
            else ...[
              Text(policy.summary, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4.0),
              Text(
                'Strength: ${snapshot.tablesOutcome == MetaTablesOutcome.loaded && snapshot.identity.postgresRoles.isNotEmpty ? 'guardrails (dbscope); real Postgres privileges cap everything' : 'guardrails (dbscope)'}',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                'Identity: ${policy.identityMode.name} · principals: '
                '${policy.principals.isEmpty ? '(none)' : policy.principals.join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                'Capabilities: ${policy.capabilities.isEmpty ? '(none)' : [for (final capability in policy.capabilities) capability.name].join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                'Default level: ${policy.defaultLevel.name}',
                style: theme.textTheme.bodySmall,
              ),
              const Divider(),
              for (final accessRow in rows)
                Tooltip(
                  message: accessRow.$4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.0),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 70.0,
                          child: Text(accessRow.$3, style: _mono),
                        ),
                        Expanded(
                          child: Text('${accessRow.$1}.${accessRow.$2}'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}

Future<void> showViewAs(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final snapshot = active.snapshot;
  if (snapshot.viewAsRoleIds != null) {
    MetadataCache.instance.viewAs(active.id, null);
    showToast(context, 'Stopped viewing as ${snapshot.policy.viewingAs}.');
    return;
  }
  if (!snapshot.policy.active) {
    showToast(context, 'This connection has no access control to preview.');
    return;
  }
  if (!_requireManage(context, snapshot)) return;
  final document = snapshot.index.document;
  final roleIds = <String>{
    for (final role in document.roles) role.id,
    for (final member in document.members) member.roleId,
    for (final grant in document.grants) grant.roleId,
  }..remove(kEveryoneRoleId);
  final chosen = <String>{};
  final result = await showDialog<Set<String>>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (dialogContext, setState) => AppFormDialog(
        title: 'View as…',
        width: 420.0,
        submitLabel: 'Preview',
        onSubmit: () => Navigator.of(dialogContext).pop(chosen),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Render dbscope as someone holding these roles (plus '
              'everyone). Choose none to preview an unlisted user. Use '
              'Metadata ▸ View as… again to stop.',
            ),
            const SizedBox(height: 8.0),
            for (final id in roleIds.toList()..sort())
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: chosen.contains(id),
                title: Text(id),
                onChanged: (checked) => setState(() {
                  if (checked ?? false) {
                    chosen.add(id);
                  } else {
                    chosen.remove(id);
                  }
                }),
              ),
          ],
        ),
      ),
    ),
  );
  if (result == null) return;
  MetadataCache.instance.viewAs(active.id, result);
}

class _CheckResult {
  const _CheckResult(this.check, {this.count, this.error});
  final CheckSpec check;
  final int? count;
  final String? error;
}

Future<void> showChecks(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final checks = active.snapshot.index.checks;
  if (checks.isEmpty) {
    showToast(context, 'The metadata defines no checks.');
    return;
  }
  final trusted = await ensureTrusted(context, active.id, TrustScope.read);
  if (!trusted || !context.mounted) return;
  final executor = ConnectionRegistry.instance.connectionFor(active.id)!;
  final results = <_CheckResult>[];
  for (final check in checks) {
    var sql = check.sql.trim();
    if (sql.endsWith(';')) sql = sql.substring(0, sql.length - 1);
    try {
      final result = await executeReadOnly(
        executor,
        'SELECT count(*) FROM ($sql) AS dbscope_check',
      );
      results.add(
        _CheckResult(check, count: (result.rows.first.first as num?)?.toInt()),
      );
    } catch (e) {
      results.add(_CheckResult(check, error: classify(e).message));
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AppFormDialog(
        title: 'Checks',
        width: 680.0,
        height: 520.0,
        submitLabel: null,
        cancelLabel: 'Close',
        content: Column(
          children: [
            for (final checkResult in results)
              ListTile(
                dense: true,
                leading: Icon(
                  checkResult.error != null
                      ? Icons.error_outline
                      : (checkResult.count ?? 0) == 0
                      ? Icons.check_circle_outline
                      : checkResult.check.severity == CheckSeverity.error
                      ? Icons.cancel_outlined
                      : Icons.warning_amber,
                  color: checkResult.error != null || (checkResult.count ?? 0) > 0
                      ? (checkResult.check.severity == CheckSeverity.info
                            ? theme.hintColor
                            : theme.colorScheme.error)
                      : Colors.green,
                ),
                title: Text(checkResult.check.label),
                subtitle: Text(
                  checkResult.error ??
                      '${checkResult.count} row(s)'
                          '${checkResult.check.description == null ? '' : ' — ${checkResult.check.description}'}',
                ),
                trailing: (checkResult.count ?? 0) > 0
                    ? TextButton(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          AppState.instance.openTab(
                            NamedQueryTab.adHoc(
                              connectionId: active.id,
                              label: 'Check: ${checkResult.check.label}',
                              sql: checkResult.check.sql,
                              boundParams: const {},
                            ),
                          );
                        },
                        child: const Text('Show rows'),
                      )
                    : null,
              ),
          ],
        ),
      );
    },
  );
}

Future<void> showMetadataSettings(BuildContext context) async {
  final id = ConnectionRegistry.instance.activeId;
  final profile = id == null ? null : ConnectionRegistry.instance.profileById(id);
  if (id == null || profile == null) {
    showToast(context, 'Pick a connection first.');
    return;
  }
  var settings = profile.metadata;
  // When the database itself carries access control, only a manager may
  // switch the tables off or point at other ones — otherwise any viewer
  // could opt out of the shared rules. Identity and the file stay editable
  // (a file can't override database access control; see MetadataCache).
  final snapshot = MetadataCache.instance.snapshotFor(id);
  final tablesLocked =
      snapshot != null &&
      snapshot.policy.active &&
      snapshot.tablesOutcome == MetaTablesOutcome.loaded &&
      !snapshot.policy.can(Capability.manage);
  final customController = TextEditingController(
    text: settings.customName ?? '',
  );
  final pathController = TextEditingController(
    text: settings.sidecarPath ?? '',
  );
  final identityController = TextEditingController(
    text: settings.claimedIdentity ?? '',
  );
  final result = await showDialog<MetadataSettings>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (dialogContext, setState) => AppFormDialog(
        title: 'Metadata settings — ${profile.name}',
        width: 560.0,
        submitLabel: 'Save',
        onSubmit: () {
          String? text(TextEditingController controller) =>
              controller.text.trim().isEmpty ? null : controller.text.trim();
          Navigator.of(dialogContext).pop(
            MetadataSettings(
              tablesMode: settings.tablesMode,
              customName: text(customController),
              sidecarPath: text(pathController),
              claimedIdentity: text(identityController),
            ),
          );
        },
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Metadata tables in the database'),
            const SizedBox(height: 4.0),
            SegmentedButton<MetaTablesMode>(
              segments: const [
                ButtonSegment(value: MetaTablesMode.auto, label: Text('Auto')),
                ButtonSegment(
                  value: MetaTablesMode.custom,
                  label: Text('Custom name'),
                ),
                ButtonSegment(value: MetaTablesMode.off, label: Text('Off')),
              ],
              selected: {settings.tablesMode},
              onSelectionChanged: tablesLocked
                  ? null
                  : (selection) => setState(
                      () => settings = settings.copyWith(
                        tablesMode: selection.first,
                      ),
                    ),
            ),
            if (tablesLocked)
              const Padding(
                padding: EdgeInsets.only(top: 4.0),
                child: Text(
                  'The database defines access control; only a role with '
                  'manage can change where dbscope reads it from.',
                  style: TextStyle(fontSize: 11.0),
                ),
              ),
            if (settings.tablesMode == MetaTablesMode.custom) ...[
              const SizedBox(height: 8.0),
              TextField(
                controller: customController,
                enabled: !tablesLocked,
                decoration: const InputDecoration(
                  labelText:
                      'Postgres schema (default dbscope) / SQLite prefix '
                      '(default _dbscope_)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 16.0),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: pathController,
                    decoration: const InputDecoration(
                      labelText: 'Metadata file (YAML or JSON), optional',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8.0),
                OutlinedButton(
                  onPressed: () async {
                    final file = await openFile(
                      acceptedTypeGroups: const [
                        XTypeGroup(
                          label: 'Metadata',
                          extensions: ['yaml', 'yml', 'json'],
                        ),
                      ],
                    );
                    if (file != null) {
                      setState(() => pathController.text = file.path);
                    }
                  },
                  child: const Text('Browse…'),
                ),
              ],
            ),
            const SizedBox(height: 16.0),
            TextField(
              controller: identityController,
              decoration: const InputDecoration(
                labelText: 'Your identity on this connection (email)',
                helperText:
                    'Matched against user:<email> role members. Claimed '
                    'identity is guardrails only.',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (result == null) return;
  await ConnectionRegistry.instance.setMetadataSettings(id, result);
  if (context.mounted) showToast(context, 'Metadata settings saved.');
}

Future<void> showInitializeTables(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final snapshot = active.snapshot;
  if (snapshot.policy.active && !_requireManage(context, snapshot)) return;
  if (ConnectionRegistry.instance.isReadOnlyFor(active.id)) {
    showToast(context, 'The connection is read-only.');
    return;
  }
  final executor = ConnectionRegistry.instance.connectionFor(active.id)!;
  final writer = MetaWriter(executor, snapshot.settings);
  final ddl = writer.createTablesSql();
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AppFormDialog(
      title: 'Initialize metadata tables',
      width: 720.0,
      height: 560.0,
      submitLabel: 'Create',
      onSubmit: () => Navigator.of(dialogContext).pop(true),
      extraActions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: ddl)),
          child: const Text('Copy SQL'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'dbscope will run this DDL. Many teams prefer to add it to their '
            'own migrations instead — copy it and close this dialog.',
          ),
          const SizedBox(height: 8.0),
          SelectableText(ddl, style: _mono),
        ],
      ),
    ),
  );
  if (ok != true) return;
  try {
    await writer.createTables();
    await ConnectionRegistry.instance.reloadMetadata(active.id);
    if (context.mounted) showToast(context, 'Metadata tables created.');
  } catch (e) {
    if (context.mounted) {
      showToast(context, 'Could not create: ${classify(e).message}');
    }
  }
}

Future<void> importMetadataFile(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final snapshot = active.snapshot;
  if (snapshot.policy.active && !_requireManage(context, snapshot)) return;
  if (snapshot.tablesOutcome != MetaTablesOutcome.loaded) {
    showToast(context, 'Create the metadata tables first (Initialize…).');
    return;
  }
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Metadata', extensions: ['yaml', 'yml', 'json']),
    ],
  );
  if (file == null || !context.mounted) return;
  final data = await FileSource.load(file.path);
  if (!context.mounted) return;
  final ok = await confirmDialog(
    context,
    title: 'Import ${file.name}?',
    message:
        '${data.rows.length} rows, ${data.roles.length} roles, '
        '${data.members.length} members and ${data.grants.length} grants '
        'will be written to the metadata tables (same ids are replaced).'
        '${data.problems.isEmpty ? '' : '\n\n${data.problems.length} problem(s) in the file: ${data.problems.first}'}',
    confirmLabel: 'Import',
  );
  if (!ok) return;
  try {
    final executor = ConnectionRegistry.instance.connectionFor(active.id)!;
    final count = await MetaWriter(
      executor,
      snapshot.settings,
    ).importSource(data);
    await ConnectionRegistry.instance.reloadMetadata(active.id);
    if (context.mounted) showToast(context, 'Imported $count entries.');
  } catch (e) {
    if (context.mounted) {
      showToast(context, 'Import failed: ${classify(e).message}');
    }
  }
}

/// Writes the merged metadata (except database comments and this
/// machine's overrides) as JSON — valid YAML too — so it can be committed.
Future<void> exportMetadataFile(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final document = active.snapshot.index.document;
  final rows = [
    for (final metaRow in document.rows)
      if (metaRow.source == MetaSourceKind.database || metaRow.source == MetaSourceKind.file)
        {
          'id': metaRow.id,
          'target': metaRow.target.raw,
          'kind': metaRow.kind,
          if (metaRow.priority != 0) 'priority': metaRow.priority,
          'spec': metaRow.spec,
        },
  ];
  final out = <String, Object?>{
    'format': kSupportedMetaFormatVersion,
    'meta': rows,
    'roles': [
      for (final role in document.roles)
        {
          'id': role.id,
          'label': role.label,
          'description': ?role.description,
          if (role.inherits.isNotEmpty) 'inherits': role.inherits,
          if (role.capabilities.isNotEmpty)
            'capabilities': [
              for (final capability in role.capabilities) capability.name,
            ],
          'db_role': ?role.dbRole,
        },
    ],
    'members': [
      for (final member in document.members) {'role': member.roleId, 'principal': member.principal},
    ],
    'grants': [
      for (final grant in document.grants)
        {
          'id': grant.id,
          'role': grant.roleId,
          'target': grant.target.raw,
          'level': grant.level.name,
          if (grant.defaultHidden) 'default_hidden': true,
          'note': ?grant.note,
        },
    ],
  };
  final location = await getSaveLocation(
    suggestedName: 'dbscope-meta.json',
    acceptedTypeGroups: const [
      XTypeGroup(label: 'JSON', extensions: ['json']),
    ],
  );
  if (location == null) return;
  try {
    await writeTextFile(
      location.path,
      const JsonEncoder.withIndent('  ').convert(out),
    );
    if (context.mounted) showToast(context, 'Exported to ${location.path}');
  } catch (e) {
    if (context.mounted) showToast(context, 'Export failed: $e');
  }
}

Future<void> showEnforcementSql(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final snapshot = active.snapshot;
  if (snapshot.isSqlite) {
    showToast(context, 'SQLite has no logins or privileges to enforce.');
    return;
  }
  if (!_requireManage(context, snapshot)) return;
  final executor = ConnectionRegistry.instance.connectionFor(active.id)!;
  final catalog = SchemaCatalog.unfiltered(executor);
  final tables = <EnforcementTable>[];
  try {
    for (final schema in await catalog.listSchemas()) {
      if (schema.isSystem) continue;
      for (final table in await catalog.listTables(schema.name)) {
        final isView = table.kind == 'VIEW';
        if (table.kind != 'BASE TABLE' && !isView) continue;
        if (snapshot.isMetaTable(table.schema, table.name)) continue;
        final columns = await catalog.listColumns(table.schema, table.name);
        final primaryKey = await catalog.primaryKey(table.schema, table.name);
        tables.add(
          EnforcementTable(
            schema: table.schema,
            table: table.name,
            columns: [for (final column in columns) column.name],
            primaryKey: primaryKey,
            isView: isView,
          ),
        );
      }
    }
  } catch (e) {
    if (context.mounted) showToast(context, classify(e).message);
    return;
  }
  final plan = buildEnforcementPlan(
    document: snapshot.index.document,
    settings: snapshot.index.rbac,
    tables: tables,
    isMetaTable: snapshot.isMetaTable,
    metaTables: [
      for (final name in MetaTableNames.logical)
        (
          schema: snapshot.settings.postgresSchema,
          table: MetaTableNames.physical(
            name,
            snapshot.settings,
            sqlite: false,
          ),
        ),
    ],
  );
  // Drift: what the database grants today vs what the plan expects.
  final drift = <String>[];
  for (final e in plan.expectations) {
    final privilege = e.privilege.name.toUpperCase();
    final sql = e.column == null
        ? 'SELECT has_table_privilege(@role, @rel, @priv)'
        : 'SELECT has_column_privilege(@role, @rel, @col, @priv)';
    try {
      final result = await executor.execute(
        sql,
        named: {
          'role': e.dbRole,
          'rel': '${quoteIdent(e.schema)}.${quoteIdent(e.table)}',
          'priv': privilege,
          if (e.column != null) 'col': e.column,
        },
      );
      final actual = result.rows.first.first == true;
      if (actual != e.granted) drift.add(e.describe);
    } catch (error) {
      drift.add('${e.describe} — could not check: ${classify(error).message}');
      break;
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AppFormDialog(
      title: 'Enforcement SQL',
      width: 760.0,
      height: 600.0,
      submitLabel: null,
      cancelLabel: 'Close',
      extraActions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: plan.script)),
          child: const Text('Copy SQL'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Review and run this yourself; dbscope never applies it. Table '
            'owners bypass privileges, so it only binds logins that do not '
            'own the tables.',
          ),
          for (final note in plan.notes) Text('• $note'),
          const SizedBox(height: 8.0),
          Text(
            drift.isEmpty
                ? 'Drift: none — the database matches the grants.'
                : 'Drift: ${drift.length} difference(s) between the grants and '
                      'the database:',
            style: Theme.of(dialogContext).textTheme.titleSmall,
          ),
          for (final difference in drift.take(_kMaxDriftLinesShown))
            Text('• $difference', style: _mono),
          const Divider(),
          SelectableText(plan.script, style: _mono),
        ],
      ),
    ),
  );
}

Future<void> showGlobalActions(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final actions = active.snapshot.index.globalActions;
  if (actions.isEmpty) {
    showToast(context, 'The metadata defines no global actions.');
    return;
  }
  final click = MetaClickContext(connectionId: active.id);
  final picked = await showDialog<ActionSpec>(
    context: context,
    builder: (dialogContext) => AppFormDialog(
      title: 'Actions',
      width: 480.0,
      submitLabel: null,
      content: Column(
        children: [
          for (final action in actions)
            ListTile(
              dense: true,
              title: Text(action.label),
              subtitle: actionUnavailableReason(action, click) == null
                  ? Text(action.run.name)
                  : Text(actionUnavailableReason(action, click)!),
              enabled: actionUnavailableReason(action, click) == null,
              onTap: () => Navigator.of(dialogContext).pop(action),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  await MetaActionRunner.run(context, picked, click);
}

Future<void> trustMetadataSql(BuildContext context) async {
  final active = _active(context);
  if (active == null) return;
  final read = await showTrustDialog(
    context,
    connectionId: active.id,
    scope: TrustScope.read,
  );
  if (read) MetaTrust.trust(active.id, active.snapshot.index, TrustScope.read);
}

void revokeMetadataTrust(BuildContext context) {
  final id = ConnectionRegistry.instance.activeId;
  if (id == null) return;
  MetaTrust.revoke(id);
  showToast(context, 'Trust revoked; metadata SQL will ask again.');
}
