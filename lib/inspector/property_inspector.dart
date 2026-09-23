import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../catalog/pg_type.dart';
import '../catalog/schema_catalog.dart';
import '../grid/cell_value_display.dart';
import '../db/edit_policy.dart';
import '../grid/inputs/column_input.dart';
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
  final void Function(String fromColumn, Object? value, List<ForeignKey> group)?
  onFollowOutbound;
  final void Function(List<ForeignKey> group)? onOpenInbound;

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

  EditPolicy _policyFor(ColumnInfo c) {
    for (final p in editPolicies) {
      if (p.column == c.name) return p;
    }
    return EditPolicy(
      schema: schema,
      table: table,
      pkColumns: pkColumns,
      column: c.name,
      type: c.type,
      typeName: c.typeName,
      nullable: c.nullable,
      isGenerated: c.isGenerated,
      isIdentity: c.isIdentity,
      readOnly: true,
      multiLine: false,
      nullIfBlank: c.nullable,
      enumValues: c.enumValues,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outboundByConstraint = <String, List<ForeignKey>>{};
    final inboundByConstraint = <String, List<ForeignKey>>{};
    final inboundByColumn = <String, List<ForeignKey>>{};
    for (final fk in foreignKeys) {
      if (fk.fromSchema == schema && fk.fromTable == table) {
        outboundByConstraint.putIfAbsent(fk.constraintKey, () => []).add(fk);
      }
      if (fk.toSchema == schema && fk.toTable == table) {
        inboundByConstraint.putIfAbsent(fk.constraintKey, () => []).add(fk);
        inboundByColumn.putIfAbsent(fk.toColumn, () => []).add(fk);
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

    void onLink(ForeignKey fk, bool incoming) {
      if (incoming) {
        if (onOpenInbound != null) onOpenInbound!([fk]);
      } else {
        if (onFollowOutbound != null) {
          final group = outboundGroupByColumn[fk.fromColumn] ?? [fk];
          onFollowOutbound!(fk.fromColumn, row[fk.fromColumn], group);
        }
      }
    }

    return SelectionArea(
      child: ListView(
        children: [
          for (final c in columns)
            PropertyFieldRow(
              column: c,
              value: row[c.name],
              policy: _policyFor(c),
              isPk: pkColumns.contains(c.name),
              outboundFk: outboundByColumn[c.name],
              inboundRefs: inboundByColumn[c.name] ?? const [],
              isFollowed: selectedFollowedColumn == c.name,
              onFollowLink: onFollowOutbound == null && onOpenInbound == null
                  ? null
                  : onLink,
              onSave: onSave,
              schema: schema,
              table: table,
              connectionId: connectionId,
            ),
          if (inboundByConstraint.isNotEmpty && onOpenInbound != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
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
  final ColumnInfo column;
  final Object? value;
  final EditPolicy policy;
  final bool isPk;
  final ForeignKey? outboundFk;
  final List<ForeignKey> inboundRefs;
  final bool isFollowed;
  final void Function(ForeignKey fk, bool incoming)? onFollowLink;
  final Future<void> Function(EditPolicy, Object?) onSave;

  /// Table identification — passed to the AI Info path so it can scope
  /// its DBML lookup correctly.
  final String? schema;
  final String? table;
  final String? connectionId;

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
  });

  @override
  State<PropertyFieldRow> createState() => _PropertyFieldRowState();
}

class _PropertyFieldRowState extends State<PropertyFieldRow> {
  bool _editing = false;
  Object? _pending;
  Object? _initial;
  final AiInfoController _aiInfo = AiInfoController();

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
  void didUpdateWidget(covariant PropertyFieldRow old) {
    super.didUpdateWidget(old);
    if (!_editing && old.value != widget.value) {
      _initial = widget.value;
      _pending = widget.value;
    }
  }

  void _startEdit() {
    if (widget.policy.readOnly) return;
    final t = widget.column.type;
    if (t == PgType.json || t == PgType.jsonb) {
      _startJsonDialogEdit();
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
    if ((widget.policy.type == PgType.json ||
            widget.policy.type == PgType.jsonb) &&
        out is String) {
      out = compactJson(out);
    }
    if (out == _initial) return;
    await widget.onSave(widget.policy, out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFk = widget.outboundFk != null;

    return Container(
      decoration: BoxDecoration(
        color: widget.isFollowed ? theme.colorScheme.primaryContainer : null,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.isPk)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.vpn_key,
                    size: 11,
                    color: theme.colorScheme.primary,
                  ),
                ),
              if (isFk)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.link,
                    size: 11,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              Expanded(
                child: Text(
                  widget.column.name,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.hintColor,
                  ),
                ),
              ),
              Text(
                widget.column.typeName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                  fontSize: 9,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          _editing ? _editor(theme) : _display(theme),
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
              onChanged: (v) => setState(() => _pending = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Save (Cmd+Enter)',
                  icon: const Icon(Icons.check, size: 16),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(2),
                  constraints: const BoxConstraints(),
                  onPressed: _commit,
                ),
                IconButton(
                  tooltip: 'Cancel (Esc)',
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(2),
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

  Widget _display(ThemeData theme) {
    final canEdit = !widget.policy.readOnly;
    final display = CellValueDisplay(
      value: widget.value,
      pgType: widget.column.type,
      columnName: widget.column.name,
      outboundFk: widget.outboundFk,
      inboundRefs: widget.inboundRefs,
      onFollowLink: widget.onFollowLink,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: canEdit ? _startEdit : null,
          onSecondaryTapDown: (details) =>
              _showContextMenu(details.globalPosition),
          child: MouseRegion(
            cursor: canEdit
                ? SystemMouseCursors.text
                : SystemMouseCursors.basic,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: display,
            ),
          ),
        ),
        AiInfoBlock(controller: _aiInfo),
      ],
    );
  }

  Future<void> _showContextMenu(Offset position) async {
    final picked = await showAppContextMenu<String>(
      context: context,
      globalPosition: position,
      items: const [
        AppMenuEntry(
          value: 'aiInfo',
          label: 'AI Info',
          icon: Icons.auto_awesome,
        ),
      ],
    );
    if (picked == 'aiInfo') {
      await _runAiInfo();
    }
  }

  Future<void> _runAiInfo() async {
    final connId = widget.connectionId;
    final schema = widget.schema;
    final table = widget.table;
    if (connId == null || schema == null || table == null) return;
    await _aiInfo.request(
      connectionId: connId,
      schema: schema,
      table: table,
      column: widget.column.name,
      typeName: widget.column.typeName,
      currentValue: widget.value,
    );
  }
}

/// One INBOUND RELATIONS link — opens a row-list of the referencing
/// table filtered by the inbound FK.
class InboundRelationRow extends StatelessWidget {
  final List<ForeignKey> group;
  final bool isSelected;
  final VoidCallback onTap;

  const InboundRelationRow({
    super.key,
    required this.group,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fk = group.first;
    final label = group.length == 1
        ? '${fk.fromTable}.${fk.fromColumn}'
        : '${fk.fromTable}.(${group.map((g) => g.fromColumn).join(', ')})';
    return InkWell(
      onTap: onTap,
      child: Container(
        color: isSelected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Icon(
              Icons.subdirectory_arrow_right,
              size: 12,
              color: theme.colorScheme.secondary,
            ),
            const SizedBox(width: 6),
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
            const Icon(Icons.chevron_right, size: 14),
          ],
        ),
      ),
    );
  }
}
