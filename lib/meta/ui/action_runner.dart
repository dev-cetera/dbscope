// Runs one metadata action: availability → trust → inputs → bind → run.
//
// Every value reaches the database as a parameter (bindSql). A value that
// is masked for the viewer can never be bound: the action refuses rather
// than send the mask (or worse, nothing) into a WHERE clause.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../../connection/registry.dart';
import '../../shell/app_state.dart';
import '../../table/table_tab.dart';
import '../../util/pg_errors.dart';
import '../action_binding.dart';
import '../masked_value.dart';
import '../meta_cache.dart';
import '../meta_models.dart';
import '../named_query/named_query_tab.dart';
import '../read_only_exec.dart';
import 'action_trust.dart';
import 'meta_dialogs.dart';
import 'meta_menu.dart';

class MetaActionRunner {
  static Future<void> run(
    BuildContext context,
    ActionSpec action,
    MetaClickContext click,
  ) async {
    final unavailable = actionUnavailableReason(action, click);
    if (unavailable != null) {
      showToast(context, unavailable);
      return;
    }
    final snapshot = MetadataCache.instance.snapshotFor(click.connectionId);
    if (snapshot == null) return;
    // The menu was built from an earlier snapshot; trust is checked against
    // the current one. If the action changed in between (a reload while the
    // menu was open), refuse rather than run SQL the user never saw.
    final current = snapshot.index.actions
        .where((candidate) => candidate.id == action.id)
        .firstOrNull;
    if (current == null ||
        current.sql != action.sql ||
        current.filter != action.filter ||
        current.template != action.template ||
        current.run != action.run) {
      showToast(context, '"${action.label}" changed; open the menu again.');
      return;
    }

    final scope = action.run.isReadOnly ? TrustScope.read : TrustScope.exec;
    final trusted = await ensureTrusted(context, click.connectionId, scope);
    if (!trusted || !context.mounted) return;

    var inputs = const <String, Object?>{};
    if (action.inputs.isNotEmpty) {
      final entered = await showInputsDialog(
        context,
        title: action.label,
        inputs: action.inputs,
      );
      if (entered == null || !context.mounted) return;
      inputs = entered;
    }
    final binding = click.binding(inputs: inputs);

    switch (action.run) {
      case ActionRun.query:
        await _runQuery(context, action, click, binding);
      case ActionRun.openTable:
        _openTable(context, action, click, binding);
      case ActionRun.exec:
        await _runExec(context, action, click, binding);
      case ActionRun.url:
        final template = action.template;
        if (template == null) {
          showToast(context, '"${action.label}" has no url template.');
          return;
        }
        await openMetadataUrl(
          context,
          renderTemplate(template, binding, encode: Uri.encodeComponent),
        );
      case ActionRun.copy:
        final template = action.template;
        if (template == null) {
          showToast(context, '"${action.label}" has no template.');
          return;
        }
        await Clipboard.setData(
          ClipboardData(text: renderTemplate(template, binding)),
        );
        if (context.mounted) showToast(context, 'Copied');
    }
  }

  /// Binds [sql] and refuses when a placeholder is missing or a bound
  /// value is masked.
  static BoundSql? _bind(
    BuildContext context,
    String? sql,
    BindingContext binding,
    String label,
  ) {
    if (sql == null) {
      showToast(context, '"$label" has no SQL.');
      return null;
    }
    final bound = bindSql(sql, binding);
    if (!bound.isComplete) {
      showToast(
        context,
        '"$label" needs ${bound.missing.map((name) => '@$name').join(', ')}.',
      );
      return null;
    }
    if (bound.named.values.any((value) => value is MaskedValue)) {
      showToast(
        context,
        '"$label" uses a value that is masked for you, so it cannot run.',
      );
      return null;
    }
    return bound;
  }

  static Future<void> _runQuery(
    BuildContext context,
    ActionSpec action,
    MetaClickContext click,
    BindingContext binding,
  ) async {
    final bound = _bind(context, action.sql, binding, action.label);
    if (bound == null) return;
    final accessTable =
        action.target.exactTable ??
        (click.isTable ? (schema: click.schema!, table: click.table!) : null);
    AppState.instance.openTab(
      NamedQueryTab.adHoc(
        connectionId: click.connectionId,
        label: action.label,
        sql: bound.sql,
        boundParams: bound.named,
        accessTable: accessTable,
      ),
    );
  }

  static void _openTable(
    BuildContext context,
    ActionSpec action,
    MetaClickContext click,
    BindingContext binding,
  ) {
    final table =
        action.table?.exactTable ??
        action.target.exactTable ??
        (click.isTable ? (schema: click.schema!, table: click.table!) : null);
    if (table == null) {
      showToast(context, '"${action.label}" needs a table.');
      return;
    }
    final bound = _bind(context, action.filter, binding, action.label);
    if (bound == null) return;
    final positional = toPositional(bound);
    AppState.instance.openTab(
      TableTab(
        connectionId: click.connectionId,
        schema: table.schema,
        table: table.table,
        metaFilter: MetaTableFilter(
          label: action.label,
          where: positional.sql,
          params: positional.params,
        ),
      ),
    );
  }

  static Future<void> _runExec(
    BuildContext context,
    ActionSpec action,
    MetaClickContext click,
    BindingContext binding,
  ) async {
    final bound = _bind(context, action.sql, binding, action.label);
    if (bound == null) return;
    final confirmText = action.confirm == null
        ? null
        : renderTemplate(action.confirm!, binding);
    final ok = await showExecConfirmDialog(
      context,
      title: action.label,
      message: confirmText,
      sql: bound.sql,
      values: bound.named,
      expectRows: action.expectRows,
    );
    if (!ok || !context.mounted) return;
    final executor = ConnectionRegistry.instance.connectionFor(
      click.connectionId,
    );
    if (executor == null) {
      showToast(context, 'Not connected.');
      return;
    }
    Future<int> execute() async {
      final result = bound.named.isEmpty
          ? await executor.execute(bound.sql)
          : await executor.execute(bound.sql, named: bound.named);
      return result.affectedRows;
    }

    try {
      final expected = action.expectRows;
      if (expected == null) {
        final affected = await execute();
        if (context.mounted) {
          showToast(context, '${action.label}: $affected row(s) affected.');
        }
        return;
      }
      // Under the metadata-session lock (no fenced read can interleave its
      // own BEGIN/COMMIT), and only when no user transaction is open — our
      // BEGIN would be a no-op and our COMMIT/ROLLBACK would end theirs.
      final affected = await withMetaSession(executor, () async {
        await ensureNoOpenTransaction(executor);
        await executor.execute('BEGIN');
        int count;
        try {
          count = await execute();
        } catch (_) {
          await executor.execute('ROLLBACK');
          rethrow;
        }
        if (count != expected) {
          await executor.execute('ROLLBACK');
        } else {
          await executor.execute('COMMIT');
        }
        return count;
      });
      if (affected != expected) {
        if (context.mounted) {
          showToast(
            context,
            '${action.label}: rolled back — expected $expected row(s), '
            'the statement touched $affected.',
          );
        }
        return;
      }
      if (context.mounted) {
        showToast(context, '${action.label}: done ($affected row(s)).');
      }
    } catch (e) {
      if (context.mounted) {
        showToast(context, '${action.label} failed: ${classify(e).message}');
      }
    }
  }
}
