part of '../navigator_view.dart';

// ---------------------------------------------------------------------------
// Row-list column (column 2 onward when listing rows of a table)
// ---------------------------------------------------------------------------

/// How long to wait after the last keystroke before re-running the filter.
const _kFilterDebounce = Duration(milliseconds: 300);

class RowListColumn extends StatefulWidget {
  const RowListColumn({
    super.key,
    required this.tab,
    required this.index,
    required this.step,
  });
  final NavigatorTab tab;
  final int index;
  final RowListStep step;

  @override
  State<RowListColumn> createState() => _RowListColumnState();
}

class _RowListColumnState extends State<RowListColumn> {
  late final TextEditingController _filterController;
  Timer? _filterDebounce;
  final _vScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _filterController = TextEditingController(text: widget.step.filterPattern);
    _vScroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadIfNeeded());
    });
  }

  @override
  void didUpdateWidget(covariant RowListColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step.id != widget.step.id) {
      _filterController.text = widget.step.filterPattern;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadIfNeeded());
      });
    }
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    _filterController.dispose();
    _vScroll.removeListener(_onScroll);
    _vScroll.dispose();
    super.dispose();
  }

  DbExecutor? _executor() => ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  void _onScroll() {
    if (!_vScroll.hasClients) return;
    final position = _vScroll.position;
    if (position.pixels > position.maxScrollExtent - 200) {
      unawaited(_loadMore());
    }
  }

  /// Builds the base WHERE clause from inbound-FK filter and regex filter.
  ({String? where, List<Object?> params}) _buildBaseWhere() {
    final step = widget.step;
    final wheres = <String>[];
    final params = <Object?>[];

    final inboundFilter = step.inboundFilter;
    if (inboundFilter != null && inboundFilter.source.isNotEmpty) {
      final placeholders = <String>[];
      for (var i = 0; i < inboundFilter.source.length; i++) {
        params.add(inboundFilter.values[i]);
        placeholders.add('\$${params.length}');
      }
      final columns = inboundFilter.source
          .map((foreignKey) => quoteIdent(foreignKey.fromColumn))
          .join(', ');
      wheres.add('($columns) = (${placeholders.join(', ')})');
    }

    // [AI Infer] mode: dropdown shows the sentinel (filterColumn==null),
    // but the actual SQL uses whatever the inferrer most recently picked.
    final column = step.filterColumn ?? step.inferredColumn;
    final pattern = step.filterPattern;
    // Only a readable column may filter: a regex on a masked one is an
    // oracle for its value. (Covers the AI-inferred pick too.)
    final readable =
        column != null &&
        step.columns.any(
          (stepColumn) =>
              stepColumn.name == column && stepColumn.accessLevel.index >= AccessLevel.read.index,
        );
    if (column != null && pattern.isNotEmpty && readable) {
      params.add(pattern);
      wheres.add('(${quoteIdent(column)})::text ~* \$${params.length}');
    }

    return (
      where: wheres.isEmpty ? null : wheres.join(' AND '),
      params: params,
    );
  }

  Future<void> _loadIfNeeded() async {
    final step = widget.step;
    if (step.data != null || step.isLoading) return;
    await _load(reset: false);
  }

  /// Fetches the first page of PK-only rows. SELECT only the PK columns
  /// — the list column doesn't need full row data; column 3 (row detail)
  /// re-fetches the full row when the user picks one.
  Future<void> _load({bool reset = true}) async {
    final step = widget.step;
    final executor = _executor();
    if (executor == null) {
      step.error = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    if (reset) step.data = null;
    step.isLoading = true;
    step.error = null;
    AppState.instance.notifyChange();

    try {
      final catalog = SchemaCatalog(executor);
      List<ColumnInfo> allColumns;
      List<String> primaryKeyColumns;
      Set<String> indexed;
      try {
        allColumns = await catalog.listColumns(step.schema, step.table);
      } catch (e) {
        throw StateError(
          'listColumns(${step.schema}.${step.table}) failed: $e',
        );
      }
      try {
        primaryKeyColumns = await catalog.primaryKey(step.schema, step.table);
      } catch (e) {
        throw StateError('primaryKey(${step.schema}.${step.table}) failed: $e');
      }
      try {
        indexed = await catalog.indexedColumns(step.schema, step.table);
      } catch (_) {
        indexed = <String>{};
      }
      // Metadata `display.rowLabel` ("{name} ({status})") turns opaque
      // keys into readable rows; fetch the label's columns alongside the
      // PK (still cheap — a handful of columns, never the whole row).
      final labelTemplate = MetadataCache.instance
          .snapshotForExecutor(executor)
          ?.index
          .displayTable(step.schema, step.table)
          .rowLabel;
      final labelColumns = labelTemplate == null
          ? const <String>{}
          : {
              for (final match in RegExp(
                r'\{([A-Za-z0-9_]+)\}',
              ).allMatches(labelTemplate))
                match.group(1)!,
            };
      final pkInfos = allColumns
          .where(
            (column) =>
                primaryKeyColumns.contains(column.name) || labelColumns.contains(column.name),
          )
          .toList();
      step.rowLabelTemplate = labelTemplate;

      final base = _buildBaseWhere();
      final pager = KeysetPager(
        conn: executor,
        schema: step.schema,
        table: step.table,
        columns: pkInfos.isEmpty ? allColumns : pkInfos,
        pkColumns: primaryKeyColumns,
        baseWhere: base.where,
        baseWhereParams: base.params,
        explicitColumns: MetadataCache.instance.policyForExecutor(executor).active,
      );
      final firstPage = await pager.fetchNext();

      if (!mounted) return;
      step.columns = allColumns;
      step.pkColumns = primaryKeyColumns;
      step.indexedColumns = indexed;
      step.editPolicies = buildEditPolicies(
        conn: executor,
        schema: step.schema,
        table: step.table,
        columns: allColumns,
        pkColumns: primaryKeyColumns,
      );
      step.catalogLoaded = true;
      step.pager = pager;
      step.data = GridData(
        columns: [
          for (final column in pkInfos.isEmpty ? allColumns : pkInfos)
            gridColumn(
              name: column.name,
              type: column.type,
              typeName: column.typeName,
              primaryKey: primaryKeyColumns.contains(column.name),
              indexed: indexed.contains(column.name),
            ),
        ],
        rows: firstPage.rows,
      );
      step.hasNextPage = !pager.isDone;
      step.isLoading = false;
      // Default is [AI Infer] (filterColumn == null). The user can pick a
      // specific column from the dropdown to bypass the inferrer.
    } catch (e) {
      if (!mounted) return;
      step.error = classify(e).message;
      step.isLoading = false;
    }
    AppState.instance.notifyChange();
  }

  Future<void> _loadMore() async {
    final step = widget.step;
    final pager = step.pager;
    if (pager == null || pager.isDone || step.isLoadingMore) return;
    step.isLoadingMore = true;
    AppState.instance.notifyChange();
    try {
      final page = await pager.fetchNext();
      if (!mounted) return;
      final existing = step.data;
      if (existing != null) {
        step.data = GridData(
          columns: existing.columns,
          rows: [...existing.rows, ...page.rows],
        );
      }
      step.hasNextPage = !pager.isDone;
      step.isLoadingMore = false;
    } catch (e) {
      if (!mounted) return;
      step.isLoadingMore = false;
      showToast(context, 'Load more failed: ${classify(e).message}');
    }
    AppState.instance.notifyChange();
  }

  void _onFilterColumnChanged(String? column) {
    // null is the explicit [AI Infer] sentinel — accept it.
    widget.step.filterColumn = column;
    // Drop the prior AI pick whenever the dropdown changes so the
    // fallback in _buildBaseWhere doesn't accidentally use a stale
    // target. A new Enter in AI Infer mode re-infers.
    widget.step.inferredColumn = null;
    if (widget.step.filterPattern.isNotEmpty && column != null) {
      unawaited(_load());
    }
  }

  void _onFilterPatternChanged(String pattern) {
    _filterDebounce?.cancel();
    // In [AI Infer] mode (filterColumn == null) keystrokes never auto-fire
    // — the user has to click the wand. This avoids leaking every keystroke
    // to the LLM and keeps token spend predictable.
    if (widget.step.filterColumn == null) {
      widget.step.filterPattern = pattern.trim();
      return;
    }
    _filterDebounce = Timer(_kFilterDebounce, () {
      if (!mounted) return;
      widget.step.filterPattern = pattern.trim();
      unawaited(_load());
    });
  }

  /// User clicked the magic-wand. Fetch 5 sample rows with all columns
  /// (the navigator's normal page only carries PK values, so we can't
  /// reuse it), pass them to the inferrer, set filterColumn to whatever
  /// it picks, and load.
  Future<void> _runAiInfer() async {
    final step = widget.step;
    final pattern = _filterController.text.trim();
    if (pattern.isEmpty) {
      showToast(context, 'Type a search term first.');
      return;
    }
    final columns = step.columns;
    if (columns.isEmpty) return;
    final executor = _executor();
    if (executor == null) {
      showToast(context, 'No connection.');
      return;
    }
    final snapshot = MetadataCache.instance.snapshotForExecutor(executor);
    if (snapshot != null && !snapshot.policy.can(Capability.ai)) {
      showToast(context, 'Your role on this connection cannot use AI.');
      return;
    }
    try {
      // A small sample with values across the columns — the inferrer needs
      // them to discriminate, not just PK values. Only columns the viewer
      // can read and the metadata lets leave the machine are sampled; the
      // rest are sent as NULL.
      final sampled = [
        for (final column in columns)
          if (column.accessLevel.atLeast(AccessLevel.read) &&
              !(snapshot?.index
                      .sensitiveColumn(step.schema, step.table, column.name)
                      .excludeFromAi ??
                  false))
            column.name,
      ];
      if (sampled.isEmpty) {
        showToast(context, 'AI: no columns may be sampled here.');
        return;
      }
      final qualified = quoteQualified(step.schema, step.table);
      final sampleResult = await executor.execute(
        'SELECT ${sampled.map(quoteIdent).join(', ')} FROM $qualified LIMIT 5',
      );
      final colByName = <String, int>{};
      for (var i = 0; i < sampleResult.columns.length; i++) {
        colByName[sampleResult.columns[i].name] = i;
      }
      // Realign sample rows so column[i] from `columns` lines up with
      // values at the same i — drops columns the sample didn't return
      // (shouldn't happen for SELECT * but keeps the inferrer honest).
      final alignedRows = <List<Object?>>[
        for (final row in sampleResult.rows)
          [
            for (final column in columns)
              if (colByName[column.name] case final index?) row[index] else null,
          ],
      ];
      final picked = await RegexInferrer.infer(
        term: pattern,
        columns: columns,
        sampleRows: alignedRows,
      );
      if (!mounted) return;
      if (picked == null) {
        showToast(context, 'AI: no plausible column matched.');
        return;
      }
      // Park the picked column on the step as the transient inferred
      // target — _load reads it via the `filterColumn ?? inferredColumn`
      // fallback. filterColumn itself stays null so the dropdown
      // remains on `[AI Infer]` and the next Enter re-runs inference.
      setState(() {
        step.inferredColumn = picked;
        step.filterPattern = pattern;
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'AI: $e');
    }
  }

  String _rowLabel(List<Object?> rowValues, List<GridColumnSpec> columns) {
    if (columns.isEmpty) return '(row)';
    final template = widget.step.rowLabelTemplate;
    if (template != null) {
      final label = renderRowLabel(template, {
        for (var i = 0; i < columns.length; i++) columns[i].name: rowValues[i],
      });
      if (label.isNotEmpty) return label;
    }
    return [
      for (var i = 0; i < columns.length; i++) '${columns[i].name}=${_short(rowValues[i])}',
    ].join(', ');
  }

  void _openRow(int rowIdx) {
    final step = widget.step;
    final data = step.data;
    if (data == null) return;
    if (step.pkColumns.isEmpty) {
      showToast(context, 'Cannot open detail: table has no primary key.');
      return;
    }
    final row = data.rows[rowIdx];
    final pkValues = <Object?>[];
    for (final primaryKey in step.pkColumns) {
      final i = data.columns.indexWhere((column) => column.name == primaryKey);
      pkValues.add(i >= 0 ? row[i] : null);
    }
    if (pkValues.any((value) => value is MaskedValue)) {
      showToast(
        context,
        "The primary key is masked for you, so this row can't be opened.",
      );
      return;
    }
    final existing = widget.tab.selectedRowPkValuesAt(widget.index);
    if (existing != null && _listEq(existing, pkValues)) {
      widget.tab.truncateTo(widget.index);
    } else {
      widget.tab.pushFrom(
        widget.index,
        RowDetailStep(
          schema: step.schema,
          table: step.table,
          pkColumns: step.pkColumns,
          pkValues: pkValues,
        ),
      );
    }
    AppState.instance.notifyChange();
  }

  Future<void> _insertRow() async {
    final step = widget.step;
    final executor = _executor();
    if (executor == null) return;
    if (!step.catalogLoaded) return;
    final rules = writeRulesFor(
      executor,
      schema: step.schema,
      table: step.table,
      columns: step.columns,
      pkColumns: step.pkColumns,
    );
    final refusal = step.pkColumns.isEmpty || step.editPolicies.isEmpty
        ? 'Cannot insert: table has no primary key.'
        : rules.whyNoInsert(pkColumns: step.pkColumns);
    if (refusal != null) {
      showToast(context, refusal);
      return;
    }
    final values = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => InsertRowDialog(policies: step.editPolicies),
    );
    if (values == null) return;
    try {
      final editor = CellEditor(executor);
      await editor.insertRow(
        schema: step.schema,
        table: step.table,
        editable: step.editPolicies.where((policy) => !policy.readOnly).toList(),
        values: values,
        returning: rules.returningList,
      );
      if (!mounted) return;
      showToast(context, 'Inserted. Reloading.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'Insert failed: ${classify(e).message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = widget.step;
    final data = step.data;
    final selectedPrimaryKey = widget.tab.selectedRowPkValuesAt(widget.index);

    String? subtitle;
    final inboundFilter = step.inboundFilter;
    if (inboundFilter != null) {
      if (inboundFilter.source.length == 1) {
        subtitle =
            'where ${inboundFilter.source.first.fromColumn} = ${_short(inboundFilter.values.first)}';
      } else {
        final columns = inboundFilter.source.map((foreignKey) => foreignKey.fromColumn).join(', ');
        final filterValuesText = inboundFilter.values.map(_short).join(', ');
        subtitle = 'where ($columns) = ($filterValuesText)';
      }
    }

    final filterRow = !step.catalogLoaded
        ? null
        : Row(
            children: [
              SizedBox(
                width: 130.0,
                child: DropdownButtonFormField<String?>(
                  // A column that stopped being readable (metadata reload,
                  // View as…) is no longer an item; fall back to AI Infer.
                  initialValue:
                      step.columns.any(
                        (column) =>
                            column.name == step.filterColumn &&
                            column.accessLevel.index >= AccessLevel.read.index,
                      )
                      ? step.filterColumn
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6.0,
                      vertical: 6.0,
                    ),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      child: Text(
                        '[AI Infer]',
                        style: TextStyle(
                          fontSize: 11.0,
                          fontStyle: FontStyle.italic,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final column in step.columns.where(
                      (column) => column.accessLevel.index >= AccessLevel.read.index,
                    ))
                      DropdownMenuItem<String?>(
                        value: column.name,
                        child: Text(
                          column.name,
                          style: const TextStyle(fontSize: 11.0),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _onFilterColumnChanged,
                ),
              ),
              const SizedBox(width: 6.0),
              // Cap the regex field width so it doesn't balloon when the
              // column is the trailing one and absorbs the remaining
              // viewport width (see _computeWidths). LayoutBuilder lets us
              // shrink to the column's actual width when it's narrow.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LayoutBuilder(
                    builder: (_, constraints) => SizedBox(
                      width: constraints.maxWidth.clamp(0.0, 240.0),
                      child: TextField(
                        controller: _filterController,
                        decoration: const InputDecoration(
                          hintText: 'regex…',
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 14.0),
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 6.0,
                            vertical: 6.0,
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 11.0,
                        ),
                        onChanged: _onFilterPatternChanged,
                        onSubmitted: (_) {
                          if (widget.step.filterColumn == null) {
                            unawaited(_runAiInfer());
                          } else {
                            unawaited(_load());
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );

    Widget body;
    if (step.error != null) {
      body = ErrorView(message: step.error!, onRetry: _load);
    } else if (data == null || (step.isLoading && data.rows.isEmpty)) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: CircularProgressIndicator(),
        ),
      );
    } else {
      body = Column(
        children: [
          if (step.pkColumns.isEmpty && step.catalogLoaded)
            const AppBanner(
              message: 'Table has no PK — rows not navigable',
              severity: BannerSeverity.error,
              dense: true,
            ),
          Expanded(
            child: ListView.builder(
              controller: _vScroll,
              itemCount: data.rows.length + (step.isLoadingMore ? 1 : 0),
              itemBuilder: (_, i) {
                if (i >= data.rows.length) {
                  return const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Center(
                      child: SizedBox(
                        height: 16.0,
                        width: 16.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      ),
                    ),
                  );
                }
                final row = data.rows[i];
                final pkValuesForRow = <Object?>[];
                for (final primaryKey in step.pkColumns) {
                  final j = data.columns.indexWhere(
                    (column) => column.name == primaryKey,
                  );
                  pkValuesForRow.add(j >= 0 ? row[j] : null);
                }
                final isSel =
                    selectedPrimaryKey != null && _listEq(selectedPrimaryKey, pkValuesForRow);
                return InkWell(
                  onTap: () => _openRow(i),
                  child: Container(
                    color: isSel ? theme.colorScheme.primaryContainer : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8.0,
                      vertical: 5.0,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.vpn_key,
                          size: 11.0,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6.0),
                        Expanded(
                          child: Text(
                            _rowLabel(row, data.columns),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'Menlo',
                              fontWeight: isSel ? FontWeight.w600 : null,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.chevron_right, size: 14.0),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (data.rows.isNotEmpty && !step.hasNextPage && !step.isLoadingMore)
            Padding(
              padding: const EdgeInsets.all(6.0),
              child: Text(
                'End of results (${data.rows.length})',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ),
        ],
      );
    }

    return AppPanel(
      rightBorder: true,
      title: step.table,
      subtitle: subtitle,
      titleIcon: Icons.table_chart_outlined,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Insert row',
            icon: const Icon(Icons.add, size: 16.0),
            onPressed: !step.catalogLoaded || step.pkColumns.isEmpty ? null : _insertRow,
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh, size: 16.0),
            onPressed: step.isLoading ? null : _load,
          ),
          if (widget.index > 0)
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
      filter: filterRow,
      child: body,
    );
  }
}

// ---------------------------------------------------------------------------
