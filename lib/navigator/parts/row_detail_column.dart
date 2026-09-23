part of '../navigator_view.dart';

// ---------------------------------------------------------------------------
// Row-detail column (column 3 / 5 / 7… — one row's fields)
// ---------------------------------------------------------------------------

class RowDetailColumn extends StatefulWidget {
  final NavigatorTab tab;
  final int index;
  final RowDetailStep step;
  const RowDetailColumn({
    super.key,
    required this.tab,
    required this.index,
    required this.step,
  });

  @override
  State<RowDetailColumn> createState() => _RowDetailColumnState();
}

class _RowDetailColumnState extends State<RowDetailColumn> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(covariant RowDetailColumn old) {
    super.didUpdateWidget(old);
    if (old.step.id != widget.step.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  DbExecutor? _conn() =>
      ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _load() async {
    final step = widget.step;
    final conn = _conn();
    if (conn == null) {
      step.error = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    step.isLoading = true;
    step.error = null;
    AppState.instance.notifyChange();
    try {
      final catalog = SchemaCatalog(conn);
      final cols = await catalog.listColumns(step.schema, step.table);
      final pk = await catalog.primaryKey(step.schema, step.table);
      final values = <Object?>[];
      for (final c in pk) {
        final i = step.pkColumns.indexOf(c);
        values.add(i >= 0 ? step.pkValues[i] : null);
      }
      final row = await catalog.loadRowByPk(
        schema: step.schema,
        table: step.table,
        pkColumns: pk,
        pkValues: values,
      );
      final policies = [
        for (final c in cols)
          EditPolicy(
            schema: step.schema,
            table: step.table,
            pkColumns: pk,
            column: c.name,
            type: c.type,
            typeName: c.typeName,
            nullable: c.nullable,
            isGenerated: c.isGenerated,
            isIdentity: c.isIdentity,
            readOnly: pk.isEmpty || c.isGenerated || c.isIdentity,
            multiLine:
                c.type == PgType.json ||
                c.type == PgType.jsonb ||
                c.type == PgType.text,
            nullIfBlank: c.nullable,
            enumValues: c.enumValues,
          ),
      ];
      if (!mounted) return;
      step.columns = cols;
      step.editPolicies = policies;
      step.row = row;
      step.isLoading = false;
      step.error = row == null
          ? 'Row not found (it may have been deleted).'
          : null;
      AppState.instance.notifyChange();
    } catch (e) {
      if (!mounted) return;
      step.error = classify(e).message;
      step.isLoading = false;
      AppState.instance.notifyChange();
    }
  }

  Future<void> _saveCell(EditPolicy policy, Object? newRaw) async {
    final step = widget.step;
    final conn = _conn();
    if (conn == null) return;
    final row = step.row;
    if (row == null) return;
    final pkValues = <String, Object?>{};
    for (final pk in policy.pkColumns) {
      pkValues[pk] = row[pk];
    }
    try {
      final editor = CellEditor(conn);
      final result = await editor.updateCell(
        policy: policy,
        pkValues: pkValues,
        oldValue: row[policy.column],
        newValueRaw: newRaw,
      );
      if (!mounted) return;
      if (result.affectedRows == 0) {
        showToast(context, 'Row changed since you loaded it. Reloading.');
        await _load();
        return;
      }
      step.row = {...row, policy.column: result.newValue};
      AppState.instance.notifyChange();
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'Update failed: ${classify(e).message}');
    }
  }

  Future<void> _delete() async {
    final step = widget.step;
    final conn = _conn();
    if (conn == null) return;
    if (step.row == null) return;
    final pk = step.editPolicies.isNotEmpty
        ? step.editPolicies.first.pkColumns
        : const <String>[];
    if (pk.isEmpty) {
      showToast(context, 'Cannot delete: no primary key.');
      return;
    }
    final pkSummary = pk
        .map((c) => '$c = ${step.row![c]}')
        .toList(growable: false)
        .join(' AND ');
    final ok = await confirmDialog(
      context,
      title: 'Delete row?',
      message: 'WHERE $pkSummary',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      final editor = CellEditor(conn);
      final pkVals = <String, Object?>{
        for (final c in pk) c: step.row![c],
      };
      await editor.deleteRow(
        schema: step.schema,
        table: step.table,
        pkColumns: pk,
        pkValues: pkVals,
      );
      if (!mounted) return;
      showToast(context, 'Deleted.');
      // Collapse this column and refresh the parent list (if any).
      widget.tab.truncateTo(widget.index - 1);
      AppState.instance.notifyChange();
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'Delete failed: ${classify(e).message}');
    }
  }

  void _followOutbound(String column, Object? value, List<ForeignKey> group) {
    if (value == null) return;
    final target = group.first;
    final selectedCol = widget.tab.selectedFollowedColumnAt(widget.index);
    if (selectedCol == column) {
      widget.tab.truncateTo(widget.index);
      AppState.instance.notifyChange();
      return;
    }
    final toPkCols = group.map((g) => g.toColumn).toList();
    final pkValues = <Object?>[];
    for (final g in group) {
      pkValues.add(widget.step.row?[g.fromColumn]);
    }
    widget.tab.pushFrom(
      widget.index,
      RowDetailStep(
        schema: target.toSchema,
        table: target.toTable,
        pkColumns: toPkCols,
        pkValues: pkValues,
        followedFromColumn: column,
      ),
    );
    AppState.instance.notifyChange();
  }

  void _openInbound(List<ForeignKey> group) {
    final selected = widget.tab.selectedInboundConstraintAt(widget.index);
    if (selected == group.first.constraintKey) {
      widget.tab.truncateTo(widget.index);
      AppState.instance.notifyChange();
      return;
    }
    final values = <Object?>[];
    for (final g in group) {
      values.add(widget.step.row?[g.toColumn]);
    }
    widget.tab.pushFrom(
      widget.index,
      RowListStep(
        schema: group.first.fromSchema,
        table: group.first.fromTable,
        inboundFilter: InboundFilter(source: group, values: values),
      ),
    );
    AppState.instance.notifyChange();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = widget.step;
    final row = step.row;

    final headerLabel = [
      for (var i = 0; i < step.pkColumns.length; i++)
        '${step.pkColumns[i]}=${_short(step.pkValues[i])}',
    ].join(', ');

    return AppPanel(
      rightBorder: true,
      title: step.table,
      subtitle: headerLabel,
      titleIcon: Icons.article_outlined,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh, size: 16),
            onPressed: step.isLoading ? null : _load,
          ),
          IconButton(
            tooltip: 'Delete row',
            icon: Icon(
              Icons.delete_outline,
              size: 16,
              color: theme.colorScheme.error,
            ),
            onPressed: row == null ? null : _delete,
          ),
          IconButton(
            tooltip: 'Close column',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () {
              widget.tab.truncateTo(widget.index - 1);
              AppState.instance.notifyChange();
            },
          ),
        ],
      ),
      child: step.error != null
          ? ErrorView(message: step.error!, onRetry: _load)
          : step.isLoading || row == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            )
          : PropertyInspector(
              schema: step.schema,
              table: step.table,
              columns: step.columns,
              row: row,
              editPolicies: step.editPolicies,
              pkColumns: step.pkColumns,
              foreignKeys: widget.tab.foreignKeys,
              connectionId: widget.tab.connectionId,
              selectedFollowedColumn: widget.tab.selectedFollowedColumnAt(
                widget.index,
              ),
              selectedInboundConstraintKey: widget.tab
                  .selectedInboundConstraintAt(widget.index),
              onSave: _saveCell,
              onFollowOutbound: _followOutbound,
              onOpenInbound: _openInbound,
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _short(Object? v) {
  if (v == null) return 'NULL';
  final s = v.toString();
  if (s.length <= 32) return s;
  return '${s.substring(0, 32)}…';
}

bool _listEq(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
