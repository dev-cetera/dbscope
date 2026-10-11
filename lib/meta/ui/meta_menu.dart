// Builds the metadata entries of every right-click menu (grid cell,
// inspector field, named-query row, sidebar table) from one place, so an
// action, link or chart shows up the same way everywhere.
//
// Hosts convert [MetaMenuItem]s into their own menu entry type
// (GridMenuEntry for the grid, AppMenuEntry for the inspector/sidebar).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:widgets/widgets.dart';

import '../../catalog/pg_type.dart';
import '../../catalog/schema_catalog.dart';
import '../../connection/registry.dart';
import '../../navigator/navigator_tab.dart';
import '../../shell/app_state.dart';
import '../../table/table_tab.dart';
import '../../util/sql_quote.dart';
import '../action_binding.dart';
import '../masked_value.dart';
import '../meta_cache.dart';
import '../meta_models.dart';
import 'action_runner.dart';
import 'meta_dialogs.dart';

/// What the user right-clicked.
class MetaClickContext {
  final String connectionId;

  /// The real table, when the row came from one.
  final String? schema;
  final String? table;

  /// The named query, when the row came from one.
  final String? queryId;

  final Map<String, Object?> row;
  final List<String> pkColumns;
  final String? column;
  final PgType? columnType;
  final Object? cell;
  final List<Map<String, Object?>> selection;

  const MetaClickContext({
    required this.connectionId,
    this.schema,
    this.table,
    this.queryId,
    this.row = const {},
    this.pkColumns = const [],
    this.column,
    this.columnType,
    this.cell,
    this.selection = const [],
  });

  bool get isTable => schema != null && table != null;
  bool get hasRow => row.isNotEmpty;

  BindingContext binding({Map<String, Object?> inputs = const {}}) {
    final snapshot = MetadataCache.instance.snapshotFor(connectionId);
    return BindingContext(
      schema: schema,
      table: table,
      column: column,
      row: row,
      primaryKey: {
        for (final pk in pkColumns)
          if (row.containsKey(pk)) pk: row[pk],
      },
      cell: cell,
      selection: selection,
      inputs: inputs,
      mePrincipal: snapshot?.mePrincipal,
    );
  }
}

class MetaMenuItem {
  final String label;
  final IconData? icon;
  final bool enabled;
  final String? disabledReason;
  final VoidCallback? onSelected;
  final bool startsGroup;

  const MetaMenuItem({
    required this.label,
    this.icon,
    this.enabled = true,
    this.disabledReason,
    this.onSelected,
    this.startsGroup = false,
  });
}

/// Every metadata entry for [click]. [context] must stay mounted while the
/// chosen entry runs (the grid / inspector / sidebar widget's context).
List<MetaMenuItem> buildMetaMenuItems(
  BuildContext context,
  MetaClickContext click,
) {
  final snapshot = MetadataCache.instance.snapshotFor(click.connectionId);
  if (snapshot == null) return const [];
  final index = snapshot.index;
  final out = <MetaMenuItem>[];

  void group(List<MetaMenuItem> items) {
    if (items.isEmpty) return;
    out.add(
      MetaMenuItem(
        label: items.first.label,
        icon: items.first.icon,
        enabled: items.first.enabled,
        disabledReason: items.first.disabledReason,
        onSelected: items.first.onSelected,
        startsGroup: true,
      ),
    );
    out.addAll(items.skip(1));
  }

  // Actions.
  final actions = <ActionSpec>[];
  if (click.isTable) {
    if (click.hasRow) {
      actions.addAll(
        index.actionsForTable(ActionScope.row, click.schema!, click.table!),
      );
    }
    if (click.selection.length > 1) {
      actions.addAll(
        index.actionsForTable(
          ActionScope.selection,
          click.schema!,
          click.table!,
        ),
      );
    }
    if (click.column != null) {
      actions.addAll(
        index.actionsForCell(click.schema!, click.table!, click.column!),
      );
    }
  } else if (click.queryId != null) {
    if (click.hasRow) {
      actions.addAll(index.actionsForQuery(ActionScope.row, click.queryId!));
    }
    if (click.column != null) {
      actions.addAll(
        index.actionsForQueryCell(click.queryId!, click.column!),
      );
    }
  }
  group([
    for (final a in actions)
      if (whenHolds(a, click.binding()) && !_globMissesRow(a, click))
        actionMenuItem(context, a, click),
  ]);

  // Links on the clicked column.
  group(_linkItems(context, click));

  // Row charts.
  if (click.isTable && click.hasRow) {
    final charts = index.rowChartsForTable(click.schema!, click.table!);
    if (charts.isNotEmpty) {
      group([
        MetaMenuItem(
          label: 'Charts for this row…',
          icon: Icons.insert_chart_outlined,
          onSelected: () => showRowChartsDialog(context, click, charts),
        ),
      ]);
    }
  }

  // About.
  final tail = <MetaMenuItem>[];
  if (click.column != null && (click.isTable || click.queryId != null)) {
    final masked = click.cell is MaskedValue;
    tail.add(
      MetaMenuItem(
        label: masked ? 'Why is this masked?' : 'About "${click.column}"…',
        icon: masked ? Icons.visibility_off_outlined : Icons.info_outline,
        onSelected: () => showAboutColumnDialog(context, click),
      ),
    );
  }
  group(tail);
  return out;
}

/// A glob-targeted action (`*.*`) that needs columns this row doesn't have
/// is simply not offered here — it was written for other tables. An action
/// aimed at one exact table still shows, disabled with the reason.
bool _globMissesRow(ActionSpec action, MetaClickContext click) {
  if (action.target.exactTable != null || action.target.exactQueryId != null) {
    return false;
  }
  final text = action.sql ?? action.filter;
  if (text == null) return false;
  return missingRowPlaceholders(text, click.binding()).isNotEmpty;
}

/// One action as a menu item, enabled or disabled with the reason.
MetaMenuItem actionMenuItem(
  BuildContext context,
  ActionSpec action,
  MetaClickContext click,
) {
  final reason = actionUnavailableReason(action, click);
  final label = action.group == null
      ? action.label
      : '${action.group} ▸ ${action.label}';
  return MetaMenuItem(
    label: action.run == ActionRun.exec ? '$label…' : label,
    icon: _iconFor(action.run),
    enabled: reason == null,
    disabledReason: reason,
    onSelected: () => MetaActionRunner.run(context, action, click),
  );
}

IconData _iconFor(ActionRun run) => switch (run) {
  ActionRun.query => Icons.manage_search,
  ActionRun.openTable => Icons.table_chart_outlined,
  ActionRun.exec => Icons.bolt,
  ActionRun.url => Icons.open_in_new,
  ActionRun.copy => Icons.copy,
};

/// Null when [action] can run for [click]; otherwise why not.
String? actionUnavailableReason(ActionSpec action, MetaClickContext click) {
  final snapshot = MetadataCache.instance.snapshotFor(click.connectionId);
  if (snapshot == null) return 'Metadata is still loading.';
  final policy = snapshot.policy;
  if (action.roles.isNotEmpty &&
      policy.active &&
      !action.roles.any(policy.roleIds.contains)) {
    return 'Only for roles: ${action.roles.join(', ')}.';
  }
  final target = action.target;
  AccessLevel targetLevel;
  final exactTable =
      target.exactTable ??
      (click.isTable ? (schema: click.schema!, table: click.table!) : null);
  if (click.queryId != null && target.exactQueryId != null) {
    targetLevel = policy.forQuery(click.queryId!).level;
  } else if (exactTable != null) {
    targetLevel = policy.forTable(exactTable.schema, exactTable.table).level;
  } else {
    targetLevel = policy.active ? policy.defaultLevel : AccessLevel.full;
  }
  if (action.run == ActionRun.exec) {
    if (!policy.can(Capability.exec)) {
      return 'Write actions need the exec capability.';
    }
    if (!targetLevel.atLeast(AccessLevel.edit)) {
      return 'Your access here is ${targetLevel.name}; this action writes.';
    }
    if (ConnectionRegistry.instance.isReadOnlyFor(click.connectionId)) {
      return 'The connection is read-only.';
    }
    final exec = ConnectionRegistry.instance.connectionFor(click.connectionId);
    if (action.expectRows != null &&
        exec != null &&
        !exec.capabilities.transactions) {
      return 'This backend has no transactions, so expectRows cannot be '
          'checked.';
    }
  } else if (!targetLevel.atLeast(AccessLevel.read)) {
    return 'Your access here is ${targetLevel.name}.';
  }
  final text = action.sql ?? action.filter;
  if (text != null) {
    final missing = missingRowPlaceholders(text, click.binding());
    if (missing.isNotEmpty) {
      return 'Needs ${missing.map((m) => '@$m').join(', ')}, which this row '
          'does not have.';
    }
  }
  return null;
}

List<MetaMenuItem> _linkItems(BuildContext context, MetaClickContext click) {
  final column = click.column;
  if (column == null) return const [];
  final snapshot = MetadataCache.instance.snapshotFor(click.connectionId);
  if (snapshot == null) return const [];
  final links = click.isTable
      ? snapshot.index.linksForColumn(click.schema!, click.table!, column)
      : click.queryId != null
      ? snapshot.index.linksForQueryColumn(click.queryId!, column)
      : const <LinkSpec>[];
  final out = <MetaMenuItem>[];
  final cell = click.cell;
  final hasValue = cell != null && cell is! MaskedValue;
  for (final link in links) {
    if (link.isUrl) {
      out.add(
        MetaMenuItem(
          label: link.urlLabel ?? 'Open link',
          icon: Icons.open_in_new,
          enabled: hasValue,
          disabledReason: 'No value to link.',
          onSelected: () => openMetadataUrl(
            context,
            renderTemplate(
              link.urlTemplate!,
              click.binding(),
              encode: Uri.encodeComponent,
            ),
          ),
        ),
      );
      continue;
    }
    final target = resolveLinkTarget(link, click);
    if (target == null) continue;
    final level = snapshot.policy.forTable(target.schema, target.table).level;
    final value = link.jsonPath == null
        ? cell
        : _jsonPathValue(cell, link.jsonPath!);
    out.add(
      MetaMenuItem(
        label: 'Open ${target.table} row',
        icon: Icons.link,
        enabled:
            value != null &&
            value is! MaskedValue &&
            level.atLeast(AccessLevel.masked),
        disabledReason: level == AccessLevel.none
            ? '${target.table} is not available to you.'
            : 'No value to follow.',
        onSelected: () => _openRow(
          click.connectionId,
          target.schema,
          target.table,
          target.column,
          value,
        ),
      ),
    );
  }
  return out;
}

/// The (schema, table, column) a non-URL link points at for this row, or
/// null when it can't be resolved (e.g. a polymorphic kind with no table).
({String schema, String table, String column})? resolveLinkTarget(
  LinkSpec link,
  MetaClickContext click,
) {
  final to = link.to?.exactColumn;
  if (to != null) return to;
  if (!link.isPolymorphic) return null;
  final kindValue = click.row[link.polymorphicBy!];
  if (kindValue == null || kindValue is MaskedValue) return null;
  final kind = kindValue.toString();
  final mapped = link.polymorphicMap[kind]?.exactColumn;
  if (mapped != null) return mapped;
  final transform = link.polymorphicTable;
  if (transform == null) return null;
  return (
    schema: link.polymorphicSchema ?? click.schema ?? 'public',
    table: transform.apply(kind),
    column: link.polymorphicColumn,
  );
}

Object? _jsonPathValue(Object? cell, String path) {
  Object? current = cell;
  if (current is String) {
    try {
      current = jsonDecode(current);
    } catch (_) {
      return null;
    }
  }
  final parts = path.replaceFirst(RegExp(r'^\$\.?'), '').split('.');
  for (final part in parts) {
    if (part.isEmpty) continue;
    if (current is Map) {
      current = current[part];
    } else {
      return null;
    }
  }
  return current;
}

/// Opens the row [column] = [value] of [schema].[table]: the Navigator's
/// row detail when [column] is the table's whole primary key, else a table
/// tab filtered to the matching rows (a polymorphic or virtual link may
/// point at a non-key column).
Future<void> _openRow(
  String connectionId,
  String schema,
  String table,
  String column,
  Object? value,
) async {
  final executor = ConnectionRegistry.instance.connectionFor(connectionId);
  if (executor == null) return;
  var pk = const <String>[];
  try {
    pk = await SchemaCatalog.unfiltered(executor).primaryKey(schema, table);
  } catch (_) {
    // Unknown key: fall through to the filtered table.
  }
  if (pk.length == 1 && pk.single == column) {
    final tab = NavigatorTab(connectionId: connectionId);
    tab.steps.add(
      RowDetailStep(
        schema: schema,
        table: table,
        pkColumns: [column],
        pkValues: [value],
      ),
    );
    AppState.instance.openTab(tab);
    return;
  }
  AppState.instance.openTab(
    TableTab(
      connectionId: connectionId,
      schema: schema,
      table: table,
      metaFilter: MetaTableFilter(
        label: '$column = $value',
        where: '${quoteIdent(column)} = \$1',
        params: [value],
      ),
    ),
  );
}

/// Convert to the inspector/sidebar's AppMenuEntry list, plus a handler
/// map keyed by the entry value.
({List<AppMenuEntry<String>> entries, Map<String, VoidCallback> handlers})
toAppMenu(List<MetaMenuItem> items, {String prefix = 'meta:'}) {
  final entries = <AppMenuEntry<String>>[];
  final handlers = <String, VoidCallback>{};
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item.startsGroup) entries.add(const AppMenuEntry.divider());
    final key = '$prefix$i';
    entries.add(
      AppMenuEntry(
        value: key,
        label: item.enabled || item.disabledReason == null
            ? item.label
            : '${item.label} — ${item.disabledReason}',
        icon: item.icon,
        enabled: item.enabled,
      ),
    );
    if (item.onSelected != null) handlers[key] = item.onSelected!;
  }
  return (entries: entries, handlers: handlers);
}

/// Opens a URL that came from metadata. Only http(s) and mailto: a link
/// template in the database must not be able to launch `file:`, `smb:` or
/// an arbitrary app scheme on the viewer's machine.
Future<void> openMetadataUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url.trim());
  const allowed = {'http', 'https', 'mailto'};
  if (uri == null || !allowed.contains(uri.scheme.toLowerCase())) {
    showToast(
      context,
      'Not opened: only http, https and mailto links are allowed.',
    );
    return;
  }
  try {
    await launchUrl(uri);
  } catch (e) {
    if (context.mounted) showToast(context, 'Could not open $url: $e');
  }
}

/// Copies [text] and confirms with a toast.
Future<void> copyWithToast(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showToast(context, 'Copied');
}
