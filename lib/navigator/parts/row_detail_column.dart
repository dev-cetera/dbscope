part of '../navigator_view.dart';

// ---------------------------------------------------------------------------
// Row-detail column (column 3 / 5 / 7… — one row's fields)
// ---------------------------------------------------------------------------

class RowDetailColumn extends StatefulWidget {
  const RowDetailColumn({
    super.key,
    required this.tab,
    required this.index,
    required this.step,
  });
  final NavigatorTab tab;
  final int index;
  final RowDetailStep step;

  @override
  State<RowDetailColumn> createState() => _RowDetailColumnState();
}

class _RowDetailColumnState extends State<RowDetailColumn> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void didUpdateWidget(covariant RowDetailColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step.id != widget.step.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
  }

  DbExecutor? _executor() => ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _load() async {
    final step = widget.step;
    final executor = _executor();
    if (executor == null) {
      step.error = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    step.isLoading = true;
    step.error = null;
    AppState.instance.notifyChange();
    try {
      final catalog = SchemaCatalog(executor);
      final columns = await catalog.listColumns(step.schema, step.table);
      final primaryKeyColumns = await catalog.primaryKey(
        step.schema,
        step.table,
      );
      final values = <Object?>[];
      for (final primaryKeyColumn in primaryKeyColumns) {
        final i = step.pkColumns.indexOf(primaryKeyColumn);
        values.add(i >= 0 ? step.pkValues[i] : null);
      }
      final row = await catalog.loadRowByPk(
        schema: step.schema,
        table: step.table,
        pkColumns: primaryKeyColumns,
        pkValues: values,
      );
      final policies = buildEditPolicies(
        conn: executor,
        schema: step.schema,
        table: step.table,
        columns: columns,
        pkColumns: primaryKeyColumns,
      );
      if (!mounted) return;
      step.columns = columns;
      step.editPolicies = policies;
      step.row = row;
      step.isLoading = false;
      step.error = row == null ? 'Row not found (it may have been deleted).' : null;
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
    final executor = _executor();
    if (executor == null) return;
    final row = step.row;
    if (row == null) return;
    final pkValues = <String, Object?>{};
    for (final primaryKey in policy.pkColumns) {
      pkValues[primaryKey] = row[primaryKey];
    }
    try {
      final editor = CellEditor(executor);
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
    final executor = _executor();
    if (executor == null) return;
    if (step.row == null) return;
    final primaryKeyColumns = step.editPolicies.isNotEmpty
        ? step.editPolicies.first.pkColumns
        : const <String>[];
    final primaryKeyValues = <String, Object?>{
      for (final column in primaryKeyColumns) column: step.row![column],
    };
    final rules = writeRulesFor(
      executor,
      schema: step.schema,
      table: step.table,
      columns: step.columns,
      pkColumns: primaryKeyColumns,
      profile: ConnectionRegistry.instance.profileById(
        widget.tab.connectionId,
      ),
    );
    final refusal = rules.whyNoDelete(
      pkColumns: primaryKeyColumns,
      pkValues: primaryKeyValues,
    );
    if (refusal != null) {
      showToast(context, refusal);
      return;
    }
    final softColumn = rules.softDeleteColumn;
    final pkSummary = primaryKeyColumns
        .map((column) => '$column = ${step.row![column]}')
        .toList(growable: false)
        .join(' AND ');
    final ok = await confirmDialog(
      context,
      title: softColumn == null ? 'Delete row?' : 'Soft-delete row?',
      message: softColumn == null
          ? 'WHERE $pkSummary'
          : 'UPDATE ${step.schema}.${step.table} SET $softColumn = now()\n'
                'WHERE $pkSummary',
      confirmLabel: softColumn == null ? 'Delete' : 'Soft-delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      final editor = CellEditor(executor);
      if (softColumn == null) {
        await editor.deleteRow(
          schema: step.schema,
          table: step.table,
          pkColumns: primaryKeyColumns,
          pkValues: primaryKeyValues,
        );
      } else {
        await editor.softDeleteRow(
          schema: step.schema,
          table: step.table,
          pkColumns: primaryKeyColumns,
          pkValues: primaryKeyValues,
          deletedColumn: softColumn,
        );
      }
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
    final selectedColumn = widget.tab.selectedFollowedColumnAt(widget.index);
    if (selectedColumn == column) {
      widget.tab.truncateTo(widget.index);
      AppState.instance.notifyChange();
      return;
    }
    final toPrimaryKeyColumns = group.map((foreignKey) => foreignKey.toColumn).toList();
    final pkValues = <Object?>[];
    for (final foreignKey in group) {
      pkValues.add(widget.step.row?[foreignKey.fromColumn]);
    }
    widget.tab.pushFrom(
      widget.index,
      RowDetailStep(
        schema: target.toSchema,
        table: target.toTable,
        pkColumns: toPrimaryKeyColumns,
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
    for (final foreignKey in group) {
      values.add(widget.step.row?[foreignKey.toColumn]);
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
            icon: const Icon(Icons.refresh, size: 16.0),
            onPressed: step.isLoading ? null : _load,
          ),
          IconButton(
            tooltip: 'Delete row',
            icon: Icon(
              Icons.delete_outline,
              size: 16.0,
              color: theme.colorScheme.error,
            ),
            onPressed: row == null ? null : _delete,
          ),
          IconButton(
            tooltip: 'Close column',
            icon: const Icon(Icons.close, size: 16.0),
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
                padding: EdgeInsets.all(16.0),
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
              selectedInboundConstraintKey: widget.tab.selectedInboundConstraintAt(widget.index),
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

/// Longest value shown in the column header before it is cut with "…".
const _kShortValueMaxLength = 32;

String _short(Object? value) {
  if (value == null) return 'NULL';
  final text = value.toString();
  if (text.length <= _kShortValueMaxLength) return text;
  return '${text.substring(0, _kShortValueMaxLength)}…';
}

bool _listEq(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
