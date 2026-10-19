/// @docImport 'package:data_grid/data_grid.dart';
/// @docImport '../grid/typed_value_text.dart';
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../db/edit_policy.dart';
import '../grid/cell_value_display.dart';
import '../grid/inputs/column_input.dart';
import '../meta/masked_value.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../meta/ui/description_tooltip.dart';
import '../meta/ui/meta_menu.dart';
import 'ai_info_block.dart';

/// Renders one row as a vertical list of field rows, plus an optional
/// section of inbound-relation links. Used in two places:
///
/// 1. The Navigator's `RowDetailColumn` — the third (and deeper)
/// column when walking from a row list into a single row.
/// 2. The Table view's right-side panel — same row contents, opened
/// by selecting a row in the grid.
///
/// Values are rendered with [TypedValueText] so coloring matches the
/// grid's typed view mode. Editable rows commit edits through [onSave]
/// using the same [EditPolicy]/[CellEditor] path the grid uses, so
/// optimistic-concurrency guarantees are preserved.
///
/// FK navigation is optional: when [onFollowOutbound] / [onOpenInbound]
/// are null, FK values still render with the typed color but are not
/// tap-followable. The table-view callsite uses this to render rich
/// data without spawning navigator columns.
class PropertyInspector extends StatelessWidget {
  const PropertyInspector({
    super.key,
    required this.schema,
    required this.table,
    required this.columns,
    required this.row,
    required this.editPolicies,
    required this.pkColumns,
    required this.foreignKeys,
    required this.onSave,
    this.connectionId,
    this.selectedFollowedColumn,
    this.selectedInboundConstraintKey,
    this.onFollowOutbound,
    this.onOpenInbound,
  });
  final String schema;
  final String table;
  final List<ColumnInfo> columns;
  final Map<String, Object?> row;
  final List<EditPolicy> editPolicies;
  final List<String> pkColumns;
  final List<ForeignKey> foreignKeys;

  /// Used by the right-click "AI Info" affordance to look up the
  /// matching DBML cache entry. When null, the affordance is hidden.
  final String? connectionId;

  /// Column name in [row] that is currently followed (highlighted) by
  /// the next navigator column. Null when no follow is active.
  final String? selectedFollowedColumn;

  /// Constraint key of the inbound group currently expanded as a
  /// child column in the navigator. Null when none.
  final String? selectedInboundConstraintKey;

  final Future<void> Function(EditPolicy policy, Object? newRaw) onSave;
  final void Function(String fromColumn, Object? value, List<ForeignKey> group)? onFollowOutbound;
  final void Function(List<ForeignKey> group)? onOpenInbound;

  EditPolicy _policyFor(ColumnInfo column) {
    for (final policy in editPolicies) {
      if (policy.column == column.name) return policy;
    }
    return EditPolicy(
      schema: schema,
      table: table,
      pkColumns: pkColumns,
      column: column.name,
      type: column.type,
      typeName: column.typeName,
      nullable: column.nullable,
      isGenerated: column.isGenerated,
      isIdentity: column.isIdentity,
      readOnly: true,
      multiLine: false,
      nullIfBlank: column.nullable,
      enumValues: column.enumValues,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outboundByConstraint = <String, List<ForeignKey>>{};
    final inboundByConstraint = <String, List<ForeignKey>>{};
    final inboundByColumn = <String, List<ForeignKey>>{};
    for (final foreignKey in foreignKeys) {
      if (foreignKey.fromSchema == schema && foreignKey.fromTable == table) {
        outboundByConstraint.putIfAbsent(foreignKey.constraintKey, () => []).add(foreignKey);
      }
      if (foreignKey.toSchema == schema && foreignKey.toTable == table) {
        inboundByConstraint.putIfAbsent(foreignKey.constraintKey, () => []).add(foreignKey);
        inboundByColumn.putIfAbsent(foreignKey.toColumn, () => []).add(foreignKey);
      }
    }
    final outboundByColumn = <String, ForeignKey>{};
    final outboundGroupByColumn = <String, List<ForeignKey>>{};
    for (final entry in outboundByConstraint.entries) {
      if (entry.value.length == 1) {
        outboundByColumn[entry.value.first.fromColumn] = entry.value.first;
        outboundGroupByColumn[entry.value.first.fromColumn] = entry.value;
      }
    }

    void onLink(ForeignKey foreignKey, {required bool incoming}) {
      if (incoming) {
        onOpenInbound?.call([foreignKey]);
      } else {
        if (onFollowOutbound != null) {
          final group = outboundGroupByColumn[foreignKey.fromColumn] ?? [foreignKey];
          onFollowOutbound!(
            foreignKey.fromColumn,
            row[foreignKey.fromColumn],
            group,
          );
        }
      }
    }

    return SelectionArea(
      child: ListView(
        children: [
          for (final column in columns)
            PropertyFieldRow(
              column: column,
              value: row[column.name],
              policy: _policyFor(column),
              isPk: pkColumns.contains(column.name),
              outboundFk: outboundByColumn[column.name],
              inboundRefs: inboundByColumn[column.name] ?? const [],
              isFollowed: selectedFollowedColumn == column.name,
              onFollowLink: onFollowOutbound == null && onOpenInbound == null ? null : onLink,
              onSave: onSave,
              schema: schema,
              table: table,
              connectionId: connectionId,
              row: row,
              pkColumns: pkColumns,
            ),
          if (inboundByConstraint.isNotEmpty && onOpenInbound != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 4.0),
              child: Text(
                'INBOUND RELATIONS',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            for (final entry in inboundByConstraint.entries)
              InboundRelationRow(
                group: entry.value,
                isSelected: selectedInboundConstraintKey == entry.key,
                onTap: () => onOpenInbound!(entry.value),
              ),
          ],
        ],
      ),
    );
  }
}

/// One field row: label, type, value (with typed coloring + URL /
/// link / JSON expand affordances), and inline edit-on-double-click
/// for editable rows.
class PropertyFieldRow extends StatefulWidget {
  const PropertyFieldRow({
    super.key,
    required this.column,
    required this.value,
    required this.policy,
    required this.isPk,
    required this.outboundFk,
    required this.inboundRefs,
    required this.isFollowed,
    required this.onFollowLink,
    required this.onSave,
    this.schema,
    this.table,
    this.connectionId,
    this.row = const {},
    this.pkColumns = const [],
  });
  final ColumnInfo column;
  final Object? value;
  final EditPolicy policy;
  final bool isPk;
  final ForeignKey? outboundFk;
  final List<ForeignKey> inboundRefs;
  final bool isFollowed;
  final void Function(ForeignKey foreignKey, {required bool incoming})? onFollowLink;
  final Future<void> Function(EditPolicy, Object?) onSave;

  /// Table identification — passed to the AI Info path so it can scope
  /// its DBML lookup correctly.
  final String? schema;
  final String? table;
  final String? connectionId;

  /// The whole row and its primary key, for metadata actions and links.
  final Map<String, Object?> row;
  final List<String> pkColumns;

  @override
  State<PropertyFieldRow> createState() => _PropertyFieldRowState();
}

class _PropertyFieldRowState extends State<PropertyFieldRow> {
  var _editing = false;
  Object? _pending;
  Object? _initial;
  final _aiInfo = AiInfoController();

  @override
  void initState() {
    super.initState();
    _initial = widget.value;
    _pending = widget.value;
  }

  @override
  void dispose() {
    _aiInfo.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PropertyFieldRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && oldWidget.value != widget.value) {
      _initial = widget.value;
      _pending = widget.value;
    }
  }

  /// The metadata snapshot for this row's connection, when it came from a
  /// real table.
  MetaSnapshot? get _snapshot {
    final id = widget.connectionId;
    return id == null ? null : MetadataCache.instance.snapshotFor(id);
  }

  void _startEdit() {
    if (widget.policy.readOnly) {
      final reason = widget.policy.readOnlyReason;
      if (reason != null) showToast(context, reason);
      return;
    }
    final type = widget.column.type;
    if (type == PgType.json || type == PgType.jsonb) {
      unawaited(_startJsonDialogEdit());
      return;
    }
    setState(() {
      _editing = true;
      _initial = widget.value;
      _pending = widget.value;
    });
  }

  Future<void> _startJsonDialogEdit() async {
    final result = await showJsonEditorDialog(
      context,
      columnName: widget.column.name,
      currentValue: jsonSourceOf(widget.value),
    );
    if (result == null) return;
    if (result == widget.value) return;
    await widget.onSave(widget.policy, result);
  }

  void _cancel() => setState(() => _editing = false);

  Future<void> _commit() async {
    setState(() => _editing = false);
    var out = _pending;
    if ((widget.policy.type == PgType.json || widget.policy.type == PgType.jsonb) &&
        out is String) {
      out = compactJson(out);
    }
    if (out == _initial) return;
    await widget.onSave(widget.policy, out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isForeignKey = widget.outboundFk != null;

    return Container(
      decoration: BoxDecoration(
        color: widget.isFollowed ? theme.colorScheme.primaryContainer : null,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.isPk)
                Padding(
                  padding: const EdgeInsets.only(right: 4.0),
                  child: Icon(
                    Icons.vpn_key,
                    size: 11.0,
                    color: theme.colorScheme.primary,
                  ),
                ),
              if (isForeignKey)
                Padding(
                  padding: const EdgeInsets.only(right: 4.0),
                  child: Icon(
                    Icons.link,
                    size: 11.0,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTapDown: (details) => _showContextMenu(details.globalPosition),
                  child: DescriptionTooltip(
                    markdown: _description(),
                    child: Text(
                      widget.column.name,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.hintColor,
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.column.isMasked)
                Tooltip(
                  message: 'Masked for you. Right-click for why.',
                  child: Icon(
                    Icons.visibility_off_outlined,
                    size: 11.0,
                    color: theme.hintColor,
                  ),
                )
              else if (widget.policy.readOnlyReason != null)
                Tooltip(
                  message: widget.policy.readOnlyReason,
                  child: Icon(
                    Icons.lock_outline,
                    size: 11.0,
                    color: theme.hintColor,
                  ),
                ),
              const SizedBox(width: 4.0),
              Text(
                widget.column.typeName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                  fontSize: 9.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2.0),
          if (_editing) _editor(theme) else _display(theme),
        ],
      ),
    );
  }

  Widget _editor(ThemeData theme) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _commit,
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ColumnInput.forPolicy(
              policy: widget.policy,
              value: _pending,
              onChanged: (value) => setState(() => _pending = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 18.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Save (Cmd+Enter)',
                  icon: const Icon(Icons.check, size: 16.0),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(2.0),
                  constraints: const BoxConstraints(),
                  onPressed: _commit,
                ),
                IconButton(
                  tooltip: 'Cancel (Esc)',
                  icon: const Icon(Icons.close, size: 16.0),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(2.0),
                  constraints: const BoxConstraints(),
                  onPressed: _cancel,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _description() {
    final schema = widget.schema;
    final table = widget.table;
    final snapshot = _snapshot;
    if (schema == null || table == null || snapshot == null) return '';
    return snapshot.index.describeColumn(schema, table, widget.column.name).toMarkdown();
  }

  DisplaySpec? _displaySpec() {
    final schema = widget.schema;
    final table = widget.table;
    final snapshot = _snapshot;
    if (schema == null || table == null || snapshot == null) return null;
    return snapshot.index.displayColumn(schema, table, widget.column.name);
  }

  Widget _display(ThemeData theme) {
    final canEdit = !widget.policy.readOnly;
    final display = CellValueDisplay(
      value: widget.value,
      pgType: widget.column.type,
      columnName: widget.column.name,
      outboundFk: widget.outboundFk,
      inboundRefs: widget.inboundRefs,
      onFollowLink: widget.onFollowLink,
      display: _displaySpec(),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: canEdit ? _startEdit : null,
          onSecondaryTapDown: (details) => _showContextMenu(details.globalPosition),
          child: MouseRegion(
            cursor: canEdit ? SystemMouseCursors.text : SystemMouseCursors.basic,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.0),
              child: display,
            ),
          ),
        ),
        AiInfoBlock(controller: _aiInfo),
      ],
    );
  }

  Future<void> _showContextMenu(Offset position) async {
    final connectionId = widget.connectionId;
    final policy = _snapshot?.policy;
    final aiAllowed = policy == null || policy.can(Capability.ai);
    final meta = connectionId == null
        ? null
        : toAppMenu(
            buildMetaMenuItems(
              context,
              MetaClickContext(
                connectionId: connectionId,
                schema: widget.schema,
                table: widget.table,
                row: widget.row,
                pkColumns: widget.pkColumns,
                column: widget.column.name,
                columnType: widget.column.type,
                cell: widget.value,
              ),
            ),
          );
    final picked = await showAppContextMenu<String>(
      context: context,
      globalPosition: position,
      items: [
        AppMenuEntry(
          value: 'aiInfo',
          label: aiAllowed ? 'AI Info' : 'AI Info — your role cannot use AI here',
          icon: Icons.auto_awesome,
          enabled: aiAllowed,
        ),
        ...?meta?.entries,
      ],
    );
    if (picked == 'aiInfo') {
      await _runAiInfo();
    } else if (picked != null) {
      meta?.handlers[picked]?.call();
    }
  }

  Future<void> _runAiInfo() async {
    final connId = widget.connectionId;
    final schema = widget.schema;
    final table = widget.table;
    if (connId == null || schema == null || table == null) return;
    // Never send a masked value, or one the metadata marks as staying on
    // this machine, to the AI provider: the model explains the column from
    // the schema alone instead.
    final sensitive = _snapshot?.index.sensitiveColumn(
      schema,
      table,
      widget.column.name,
    );
    final withhold = widget.value is MaskedValue || (sensitive?.excludeFromAi ?? false);
    await _aiInfo.request(
      connectionId: connId,
      schema: schema,
      table: table,
      column: widget.column.name,
      typeName: widget.column.typeName,
      currentValue: withhold ? null : widget.value,
    );
  }
}

/// One INBOUND RELATIONS link — opens a row-list of the referencing
/// table filtered by the inbound FK.
class InboundRelationRow extends StatelessWidget {
  const InboundRelationRow({
    super.key,
    required this.group,
    required this.isSelected,
    required this.onTap,
  });
  final List<ForeignKey> group;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreignKey = group.first;
    final label = group.length == 1
        ? '${foreignKey.fromTable}.${foreignKey.fromColumn}'
        : '${foreignKey.fromTable}.(${group.map((g) => g.fromColumn).join(', ')})';
    return InkWell(
      onTap: onTap,
      child: Container(
        color: isSelected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
        child: Row(
          children: [
            Icon(
              Icons.subdirectory_arrow_right,
              size: 12.0,
              color: theme.colorScheme.secondary,
            ),
            const SizedBox(width: 6.0),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'Menlo',
                  fontWeight: isSelected ? FontWeight.w600 : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right, size: 14.0),
          ],
        ),
      ),
    );
  }
}
