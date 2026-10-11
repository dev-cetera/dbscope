// Dialogs used by the metadata menus and the action runner.

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../../catalog/schema_catalog.dart';
import '../../connection/registry.dart';
import '../../db/executor.dart';
import '../../util/pg_errors.dart';
import '../access_policy.dart';
import '../charts/chart_view.dart';
import '../meta_cache.dart';
import '../meta_models.dart';
import '../meta_sources.dart';
import '../meta_writer.dart';
import '../native_facts.dart';
import 'action_trust.dart';
import 'description_tooltip.dart';
import 'meta_menu.dart';

const TextStyle _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

/// Asks the user to trust the metadata SQL of [scope] on this connection
/// when it isn't trusted yet (or changed). Returns true when it may run.
Future<bool> ensureTrusted(
  BuildContext context,
  String connectionId,
  TrustScope scope,
) async {
  final snapshot = MetadataCache.instance.snapshotFor(connectionId);
  if (snapshot == null) return false;
  if (MetaTrust.isTrusted(connectionId, snapshot.index, scope)) return true;
  final ok = await showTrustDialog(
    context,
    connectionId: connectionId,
    scope: scope,
  );
  if (ok) MetaTrust.trust(connectionId, snapshot.index, scope);
  return ok;
}

/// "Trust this metadata SQL?" Lists every SQL-bearing item of [scope] and
/// marks what changed since the last trust.
Future<bool> showTrustDialog(
  BuildContext context, {
  required String connectionId,
  required TrustScope scope,
}) async {
  final snapshot = MetadataCache.instance.snapshotFor(connectionId);
  if (snapshot == null) return false;
  final items = trustItems(snapshot.index, scope);
  final changed = MetaTrust.changedSince(connectionId, snapshot.index, scope);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AppFormDialog(
        title: scope == TrustScope.exec
            ? 'Trust write actions on this connection?'
            : 'Trust this connection\'s metadata SQL?',
        width: 680,
        height: 540,
        submitLabel: 'Trust',
        onSubmit: () => Navigator.of(ctx).pop(true),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              scope == TrustScope.exec
                  ? 'These actions WRITE to the database. Anyone who can edit '
                        'the metadata can change them, so read the SQL. You '
                        'will be asked again whenever any of it changes.'
                  : 'Queries, charts, checks, read-only actions and default '
                        'filters defined in this connection\'s metadata. '
                        'Anyone who can edit the metadata can change them. '
                        'Where the backend allows it they run in a read-only '
                        'transaction. You will be asked again whenever any of '
                        'it changes.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${changed.contains(item.id) ? '● changed  ' : ''}'
                      '${item.label}  (${item.kind} ${item.id})',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: changed.contains(item.id)
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                    SelectableText(item.text, style: _mono),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
  return result ?? false;
}

/// Prompts for an action's / query's inputs. Returns null when cancelled.
/// A `number` input that doesn't parse blocks submission (never a silent
/// NULL bound into the SQL).
Future<Map<String, Object?>?> showInputsDialog(
  BuildContext context, {
  required String title,
  required List<ActionInput> inputs,
  Map<String, String> initial = const {},
}) async {
  final controllers = {
    for (final i in inputs)
      i.name: TextEditingController(text: initial[i.name] ?? ''),
  };
  String? error;
  Map<String, Object?>? values() {
    final out = <String, Object?>{};
    for (final i in inputs) {
      final text = controllers[i.name]!.text.trim();
      if (i.type == 'number') {
        final n = num.tryParse(text);
        if (n == null) {
          error = '"${i.prompt}" must be a number.';
          return null;
        }
        out[i.name] = n;
      } else {
        out[i.name] = controllers[i.name]!.text;
      }
    }
    return out;
  }

  // The controllers are not disposed here: the dialog's TextFields still
  // use them during the exit animation after showDialog returns, and with
  // no listeners left they are simply garbage-collected.
  return showDialog<Map<String, Object?>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void submit() {
          final v = values();
          if (v == null) {
            setState(() {});
            return;
          }
          Navigator.of(ctx).pop(v);
        }

        return AppFormDialog(
          title: title,
          submitLabel: 'Run',
          onSubmit: submit,
          content: Column(
            children: [
              for (final i in inputs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: controllers[i.name],
                    autofocus: i == inputs.first,
                    keyboardType: i.type == 'number'
                        ? TextInputType.number
                        : TextInputType.text,
                    decoration: InputDecoration(
                      labelText: i.prompt,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// Confirmation for a write action: shows the SQL and every bound value.
Future<bool> showExecConfirmDialog(
  BuildContext context, {
  required String title,
  required String? message,
  required String sql,
  required Map<String, Object?> values,
  required int? expectRows,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AppFormDialog(
        title: title,
        width: 620,
        submitLabel: 'Run',
        submitIcon: Icons.bolt,
        onSubmit: () => Navigator.of(ctx).pop(true),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message != null) ...[
              Text(message, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
            ],
            SelectableText(sql, style: _mono),
            const SizedBox(height: 12),
            for (final e in values.entries)
              Text('@${e.key} = ${e.value}', style: _mono),
            const SizedBox(height: 12),
            Text(
              expectRows == null
                  ? 'Runs immediately and cannot be undone from here.'
                  : 'Runs in a transaction and rolls back unless exactly '
                        '$expectRows row(s) change.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    },
  );
  return result ?? false;
}

Future<void> showRowChartsDialog(
  BuildContext context,
  MetaClickContext click,
  List<ChartSpec> charts,
) async {
  final executor = ConnectionRegistry.instance.connectionFor(
    click.connectionId,
  );
  if (executor == null) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AppFormDialog(
      title: 'Charts for this ${click.table} row',
      width: 760,
      height: 560,
      submitLabel: null,
      cancelLabel: 'Close',
      content: Column(
        children: [
          for (final c in charts)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MetaChartCard(
                chart: c,
                executor: executor,
                row: click.binding(),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Description, access decision ("Why can't I see/edit this?"), policy and
/// links for one column, with "Edit description…" for managers.
Future<void> showAboutColumnDialog(
  BuildContext context,
  MetaClickContext click,
) async {
  final snapshot = MetadataCache.instance.snapshotFor(click.connectionId);
  if (snapshot == null || click.column == null) return;
  final index = snapshot.index;
  final policy = snapshot.policy;
  final column = click.column!;
  final DescribeSpec describe;
  final AccessDecision access;
  final List<LinkSpec> links;
  PolicySpec? columnPolicy;
  SensitiveSpec sensitive;
  if (click.isTable) {
    describe = index.describeColumn(click.schema!, click.table!, column);
    access = policy.forColumn(
      click.schema!,
      click.table!,
      column,
      isPrimaryKey: click.pkColumns.contains(column),
    );
    links = index.linksForColumn(click.schema!, click.table!, column);
    columnPolicy = index.policyColumn(click.schema!, click.table!, column);
    sensitive = index.sensitiveColumn(click.schema!, click.table!, column);
  } else {
    describe = index.describeQueryColumn(click.queryId!, column);
    access = policy.forQueryColumn(click.queryId!, column);
    links = index.linksForQueryColumn(click.queryId!, column);
    sensitive = index.sensitiveQueryColumn(click.queryId!, column);
  }
  final canEditDescription =
      click.isTable &&
      policy.can(Capability.manage) &&
      !ConnectionRegistry.instance.isReadOnlyFor(click.connectionId);

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      Widget section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      );
      return AppFormDialog(
        title: click.isTable
            ? '${click.table}.$column'
            : '${click.queryId}.$column',
        width: 560,
        submitLabel: null,
        cancelLabel: 'Close',
        extraActions: [
          if (canEditDescription)
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await showEditDescriptionDialog(
                  context,
                  connectionId: click.connectionId,
                  schema: click.schema!,
                  table: click.table!,
                  column: column,
                  initial: describe.description ?? '',
                );
              },
              child: const Text('Edit description…'),
            ),
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            section('Description', [
              if (describe.isEmpty)
                const SelectableText('No description.')
              else
                SelectableText.rich(
                  descriptionSpan(context, describe.toMarkdown()),
                ),
              if (describe.values.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final e in describe.values.entries)
                  Text(
                    '${e.key} — ${e.value}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ]),
            section(
              'Your access: ${access.level.name}'
              '${access.defaultHidden ? ' (hidden by default)' : ''}',
              [
                Text(access.reason, style: theme.textTheme.bodySmall),
                if (policy.active)
                  Text(policy.summary, style: theme.textTheme.bodySmall),
              ],
            ),
            if (columnPolicy != null &&
                (columnPolicy.readOnly ||
                    columnPolicy.pattern != null ||
                    columnPolicy.min != null ||
                    columnPolicy.max != null))
              section('Editing rules', [
                if (columnPolicy.readOnly)
                  Text('Read-only: ${columnPolicy.reason ?? 'by metadata'}'),
                if (columnPolicy.pattern != null)
                  Text('Must match ${columnPolicy.pattern}'),
                if (columnPolicy.min != null) Text('Min ${columnPolicy.min}'),
                if (columnPolicy.max != null) Text('Max ${columnPolicy.max}'),
              ]),
            if (sensitive.excludeFromAi || sensitive.excludeFromExport)
              section('Sensitive', [
                if (sensitive.excludeFromAi)
                  const Text('Never sent to an AI provider.'),
                if (sensitive.excludeFromExport)
                  const Text('Left out of exports.'),
              ]),
            if (links.isNotEmpty)
              section('Links', [
                for (final l in links)
                  Text(
                    l.isUrl
                        ? '${l.urlLabel ?? 'URL'}: ${l.urlTemplate}'
                        : l.isPolymorphic
                        ? 'Polymorphic by ${l.polymorphicBy}'
                        : '→ ${l.to?.raw}',
                    style: theme.textTheme.bodySmall,
                  ),
              ]),
          ],
        ),
      );
    },
  );
}

/// Writes a `describe` row to the metadata tables (creating nothing — the
/// tables must exist) and optionally `COMMENT ON` for other tools.
Future<void> showEditDescriptionDialog(
  BuildContext context, {
  required String connectionId,
  required String schema,
  required String table,
  String? column,
  required String initial,
}) async {
  final snapshot = MetadataCache.instance.snapshotFor(connectionId);
  final executor = ConnectionRegistry.instance.connectionFor(connectionId);
  if (snapshot == null || executor == null) return;
  final controller = TextEditingController(text: initial);
  final tablesExist = snapshot.tablesOutcome == MetaTablesOutcome.loaded;
  var alsoComment = !snapshot.isSqlite && !tablesExist;
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AppFormDialog(
        title: 'Description of ${column ?? table}',
        width: 560,
        submitLabel: 'Save',
        onSubmit: () => Navigator.of(ctx).pop(true),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            if (!tablesExist)
              const Text(
                'This connection has no metadata tables, so the description '
                'is written as a Postgres COMMENT.',
              ),
            if (tablesExist && !snapshot.isSqlite)
              CheckboxListTile(
                value: alsoComment,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Also write COMMENT ON (psql, pg_dump see it)',
                ),
                onChanged: (v) => setState(() => alsoComment = v ?? false),
              ),
          ],
        ),
      ),
    ),
  );
  final text = controller.text.trim();
  if (saved != true) return;
  final writer = MetaWriter(executor, snapshot.settings);
  try {
    if (tablesExist) {
      await writer.upsertMetaRow(
        id: describeRowId(schema, table, column),
        target: describeTarget(schema, table, column),
        kind: MetaKinds.describe,
        spec: {'description': text},
      );
    }
    if (alsoComment || !tablesExist) {
      if (snapshot.isSqlite) {
        throw StateError('SQLite has no comments; create the metadata tables.');
      }
      await writer.writeComment(
        schema: schema,
        table: table,
        column: column,
        text: text,
      );
    }
    await ConnectionRegistry.instance.reloadMetadata(connectionId);
    if (context.mounted) showToast(context, 'Description saved.');
  } catch (e) {
    if (context.mounted) {
      showToast(context, 'Could not save: ${classify(e).message}');
    }
  }
}

/// "What the database says": loads [NativeFacts] live and lists them.
/// Constraint, index and trigger definitions that mention a column hidden
/// from the viewer (`none`) are left out — they would reveal its name.
class _NativeFactsSection extends StatefulWidget {
  final String connectionId;
  final String schema;
  final String table;
  final Future<NativeFacts> Function(DbExecutor executor) load;
  const _NativeFactsSection({
    required this.connectionId,
    required this.schema,
    required this.table,
    required this.load,
  });

  @override
  State<_NativeFactsSection> createState() => _NativeFactsSectionState();
}

class _NativeFactsSectionState extends State<_NativeFactsSection> {
  Future<NativeFacts>? _future;

  @override
  void initState() {
    super.initState();
    final executor = ConnectionRegistry.instance.connectionFor(
      widget.connectionId,
    );
    if (executor != null) _future = _loadFiltered(executor);
  }

  Future<NativeFacts> _loadFiltered(DbExecutor executor) async {
    final facts = await widget.load(executor);
    final policy = MetadataCache.instance.policyForExecutor(executor);
    if (!policy.active) return facts;
    final all = await SchemaCatalog.unfiltered(
      executor,
    ).listColumns(widget.schema, widget.table);
    final visible = {
      for (final c in await SchemaCatalog(
        executor,
      ).listColumns(widget.schema, widget.table))
        c.name,
    };
    final hidden = [
      for (final c in all)
        if (!visible.contains(c.name)) c.name,
    ];
    if (hidden.isEmpty) return facts;
    final pattern = RegExp(
      '\\b(${hidden.map(RegExp.escape).join('|')})\\b',
    );
    List<NativeFact> keep(List<NativeFact> list) => [
      for (final f in list)
        if (!pattern.hasMatch(f.label) && !pattern.hasMatch(f.detail)) f,
    ];
    return NativeFacts(
      comment: facts.comment,
      attributes: keep(facts.attributes),
      constraints: keep(facts.constraints),
      indexes: keep(facts.indexes),
      triggers: keep(facts.triggers),
      policies: keep(facts.policies),
    );
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (future == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return FutureBuilder<NativeFacts>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Could not read the catalog: ${snap.error}',
              style: theme.textTheme.bodySmall,
            ),
          );
        }
        final facts = snap.data;
        if (facts == null) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        Widget group(String title, List<NativeFact> items) {
          if (items.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelMedium),
                for (final f in items)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          f.detail.isEmpty
                              ? f.label
                              : '${f.label}: ${f.detail}',
                          style: _mono,
                        ),
                        if (f.comment != null)
                          Text(
                            f.comment!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What the database says', style: theme.textTheme.labelLarge),
              if (facts.comment != null) ...[
                const SizedBox(height: 4),
                SelectableText(facts.comment!),
              ],
              group('Definition', facts.attributes),
              group('Constraints', facts.constraints),
              group('Indexes', facts.indexes),
              group('Triggers', facts.triggers),
              group('Row-level security policies', facts.policies),
            ],
          ),
        );
      },
    );
  }
}

/// Description, native facts and access for a whole table.
Future<void> showAboutTableDialog(
  BuildContext context, {
  required String connectionId,
  required String schema,
  required String table,
}) async {
  final snapshot = MetadataCache.instance.snapshotFor(connectionId);
  if (snapshot == null) return;
  final describe = snapshot.index.describeTable(schema, table);
  final access = snapshot.policy.forTable(schema, table);
  final policy = snapshot.index.policyTable(schema, table);
  final display = snapshot.index.displayTable(schema, table);
  final canEditDescription =
      snapshot.policy.can(Capability.manage) &&
      !ConnectionRegistry.instance.isReadOnlyFor(connectionId);
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AppFormDialog(
        title: '$schema.$table',
        width: 640,
        height: 600,
        submitLabel: null,
        cancelLabel: 'Close',
        extraActions: [
          if (canEditDescription)
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await showEditDescriptionDialog(
                  context,
                  connectionId: connectionId,
                  schema: schema,
                  table: table,
                  initial: describe.description ?? '',
                );
              },
              child: const Text('Edit description…'),
            ),
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!describe.isEmpty) ...[
              Text('Description', style: theme.textTheme.labelLarge),
              SelectableText.rich(
                descriptionSpan(context, describe.toMarkdown()),
              ),
              const SizedBox(height: 12),
            ],
            _NativeFactsSection(
              connectionId: connectionId,
              schema: schema,
              table: table,
              load: (executor) =>
                  loadTableFacts(executor, schema: schema, table: table),
            ),
            Text(
              'Your access: ${access.level.name}',
              style: theme.textTheme.labelLarge,
            ),
            Text(access.reason, style: theme.textTheme.bodySmall),
            if (policy.softDelete != null ||
                policy.readOnly ||
                policy.danger != null ||
                display.rowLabel != null ||
                display.group != null) ...[
              const SizedBox(height: 12),
              Text('Metadata', style: theme.textTheme.labelLarge),
              if (display.group != null) Text('Group: ${display.group}'),
              if (display.rowLabel != null)
                Text('Row label: ${display.rowLabel}'),
              if (policy.softDelete != null)
                Text('Soft-delete column: ${policy.softDelete}'),
              if (policy.readOnly)
                Text('Read-only: ${policy.reason ?? 'by metadata'}'),
              if (policy.danger != null)
                Text('Deletes: ${policy.message ?? policy.danger}'),
            ],
          ],
        ),
      );
    },
  );
}
