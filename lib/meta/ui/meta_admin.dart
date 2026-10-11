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

const TextStyle _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

/// The active connection's id and snapshot, or null with a toast.
({String id, MetaSnapshot snapshot})? _active(BuildContext context) {
  final id = ConnectionRegistry.instance.activeId;
  final snapshot = MetadataCache.instance.snapshotFor(id);
  if (id == null ||
      snapshot == null ||
      ConnectionRegistry.instance.connectionFor(id) == null) {
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
    builder: (ctx) => AppFormDialog(
      title: 'Metadata problems',
      width: 640,
      height: 480,
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
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (problems.isEmpty) const Text('No problems.'),
          for (final p in problems)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText(p.toString(), style: _mono),
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
      for (final s in await catalog.listSchemas()) {
        if (s.isSystem) continue;
        for (final t in await catalog.listTables(s.name)) {
          final d = policy.forTable(t.schema, t.name);
          rows.add((t.schema, t.name, d.level.name, d.reason));
        }
      }
    } catch (e) {
      if (context.mounted) showToast(context, classify(e).message);
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AppFormDialog(
        title: 'Your access on this connection',
        width: 720,
        height: 560,
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
              const SizedBox(height: 4),
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
                'Capabilities: ${policy.capabilities.isEmpty ? '(none)' : [for (final c in policy.capabilities) c.name].join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                'Default level: ${policy.defaultLevel.name}',
                style: theme.textTheme.bodySmall,
              ),
              const Divider(),
              for (final r in rows)
                Tooltip(
                  message: r.$4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 70,
                          child: Text(r.$3, style: _mono),
                        ),
                        Expanded(child: Text('${r.$1}.${r.$2}')),
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
    for (final r in document.roles) r.id,
    for (final m in document.members) m.roleId,
    for (final g in document.grants) g.roleId,
  }..remove(kEveryoneRoleId);
  final chosen = <String>{};
  final result = await showDialog<Set<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AppFormDialog(
        title: 'View as…',
        width: 420,
        submitLabel: 'Preview',
        onSubmit: () => Navigator.of(ctx).pop(chosen),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Render dbscope as someone holding these roles (plus '
              'everyone). Choose none to preview an unlisted user. Use '
              'Metadata ▸ View as… again to stop.',
            ),
            const SizedBox(height: 8),
            for (final id in roleIds.toList()..sort())
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: chosen.contains(id),
                title: Text(id),
                onChanged: (v) => setState(() {
                  if (v ?? false) {
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
  final CheckSpec check;
  final int? count;
  final String? error;
  const _CheckResult(this.check, {this.count, this.error});
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
      final res = await executeReadOnly(
        executor,
        'SELECT count(*) FROM ($sql) AS dbscope_check',
      );
      results.add(
        _CheckResult(check, count: (res.rows.first.first as num?)?.toInt()),
      );
    } catch (e) {
      results.add(_CheckResult(check, error: classify(e).message));
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AppFormDialog(
        title: 'Checks',
        width: 680,
        height: 520,
        submitLabel: null,
        cancelLabel: 'Close',
        content: Column(
          children: [
            for (final r in results)
              ListTile(
                dense: true,
                leading: Icon(
                  r.error != null
                      ? Icons.error_outline
                      : (r.count ?? 0) == 0
                      ? Icons.check_circle_outline
                      : r.check.severity == CheckSeverity.error
                      ? Icons.cancel_outlined
                      : Icons.warning_amber,
                  color: r.error != null || (r.count ?? 0) > 0
                      ? (r.check.severity == CheckSeverity.info
                            ? theme.hintColor
                            : theme.colorScheme.error)
                      : Colors.green,
                ),
                title: Text(r.check.label),
                subtitle: Text(
                  r.error ??
                      '${r.count} row(s)'
                          '${r.check.description == null ? '' : ' — ${r.check.description}'}',
                ),
                trailing: (r.count ?? 0) > 0
                    ? TextButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          AppState.instance.openTab(
                            NamedQueryTab.adHoc(
                              connectionId: active.id,
                              label: 'Check: ${r.check.label}',
                              sql: r.check.sql,
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
  final profile = id == null
      ? null
      : ConnectionRegistry.instance.profileById(id);
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
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AppFormDialog(
        title: 'Metadata settings — ${profile.name}',
        width: 560,
        submitLabel: 'Save',
        onSubmit: () {
          String? text(TextEditingController c) =>
              c.text.trim().isEmpty ? null : c.text.trim();
          Navigator.of(ctx).pop(
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
            const SizedBox(height: 4),
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
                  : (v) => setState(
                      () => settings = settings.copyWith(tablesMode: v.first),
                    ),
            ),
            if (tablesLocked)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'The database defines access control; only a role with '
                  'manage can change where dbscope reads it from.',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            if (settings.tablesMode == MetaTablesMode.custom) ...[
              const SizedBox(height: 8),
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
            const SizedBox(height: 16),
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
                const SizedBox(width: 8),
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
            const SizedBox(height: 16),
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
    builder: (ctx) => AppFormDialog(
      title: 'Initialize metadata tables',
      width: 720,
      height: 560,
      submitLabel: 'Create',
      onSubmit: () => Navigator.of(ctx).pop(true),
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
          const SizedBox(height: 8),
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
    for (final r in document.rows)
      if (r.source == MetaSourceKind.database ||
          r.source == MetaSourceKind.file)
        {
          'id': r.id,
          'target': r.target.raw,
          'kind': r.kind,
          if (r.priority != 0) 'priority': r.priority,
          'spec': r.spec,
        },
  ];
  final out = <String, Object?>{
    'format': kSupportedMetaFormatVersion,
    'meta': rows,
    'roles': [
      for (final r in document.roles)
        {
          'id': r.id,
          'label': r.label,
          'description': ?r.description,
          if (r.inherits.isNotEmpty) 'inherits': r.inherits,
          if (r.capabilities.isNotEmpty)
            'capabilities': [for (final c in r.capabilities) c.name],
          'db_role': ?r.dbRole,
        },
    ],
    'members': [
      for (final m in document.members)
        {'role': m.roleId, 'principal': m.principal},
    ],
    'grants': [
      for (final g in document.grants)
        {
          'id': g.id,
          'role': g.roleId,
          'target': g.target.raw,
          'level': g.level.name,
          if (g.defaultHidden) 'default_hidden': true,
          'note': ?g.note,
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
    for (final s in await catalog.listSchemas()) {
      if (s.isSystem) continue;
      for (final t in await catalog.listTables(s.name)) {
        final isView = t.kind == 'VIEW';
        if (t.kind != 'BASE TABLE' && !isView) continue;
        if (snapshot.isMetaTable(t.schema, t.name)) continue;
        final columns = await catalog.listColumns(t.schema, t.name);
        final pk = await catalog.primaryKey(t.schema, t.name);
        tables.add(
          EnforcementTable(
            schema: t.schema,
            table: t.name,
            columns: [for (final c in columns) c.name],
            primaryKey: pk,
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
        (schema: snapshot.settings.postgresSchema, table: name),
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
      final res = await executor.execute(
        sql,
        named: {
          'role': e.dbRole,
          'rel': '${quoteIdent(e.schema)}.${quoteIdent(e.table)}',
          'priv': privilege,
          if (e.column != null) 'col': e.column,
        },
      );
      final actual = res.rows.first.first == true;
      if (actual != e.granted) drift.add(e.describe);
    } catch (err) {
      drift.add('${e.describe} — could not check: ${classify(err).message}');
      break;
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AppFormDialog(
      title: 'Enforcement SQL',
      width: 760,
      height: 600,
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
          const SizedBox(height: 8),
          Text(
            drift.isEmpty
                ? 'Drift: none — the database matches the grants.'
                : 'Drift: ${drift.length} difference(s) between the grants and '
                      'the database:',
            style: Theme.of(ctx).textTheme.titleSmall,
          ),
          for (final d in drift.take(200)) Text('• $d', style: _mono),
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
    builder: (ctx) => AppFormDialog(
      title: 'Actions',
      width: 480,
      submitLabel: null,
      content: Column(
        children: [
          for (final a in actions)
            ListTile(
              dense: true,
              title: Text(a.label),
              subtitle: actionUnavailableReason(a, click) == null
                  ? Text(a.run.name)
                  : Text(actionUnavailableReason(a, click)!),
              enabled: actionUnavailableReason(a, click) == null,
              onTap: () => Navigator.of(ctx).pop(a),
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
