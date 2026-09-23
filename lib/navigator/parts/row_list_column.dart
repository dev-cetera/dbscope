part of '../navigator_view.dart';

// ---------------------------------------------------------------------------
// Row-list column (column 2 onward when listing rows of a table)
// ---------------------------------------------------------------------------

class RowListColumn extends StatefulWidget {
  final NavigatorTab tab;
  final int index;
  final RowListStep step;
  const RowListColumn({
    super.key,
    required this.tab,
    required this.index,
    required this.step,
  });

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
      if (mounted) _loadIfNeeded();
    });
  }

  @override
  void didUpdateWidget(covariant RowListColumn old) {
    super.didUpdateWidget(old);
    if (old.step.id != widget.step.id) {
      _filterController.text = widget.step.filterPattern;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadIfNeeded();
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

  DbExecutor? _conn() =>
      ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  void _onScroll() {
    if (!_vScroll.hasClients) return;
    final pos = _vScroll.position;
    if (pos.pixels > pos.maxScrollExtent - 200) _loadMore();
  }

  /// Builds the base WHERE clause from inbound-FK filter and regex filter.
  ({String? where, List<Object?> params}) _buildBaseWhere() {
    final step = widget.step;
    final wheres = <String>[];
    final params = <Object?>[];

    final inb = step.inboundFilter;
    if (inb != null && inb.source.isNotEmpty) {
      final placeholders = <String>[];
      for (var i = 0; i < inb.source.length; i++) {
        params.add(inb.values[i]);
        placeholders.add('\$${params.length}');
      }
      final cols = inb.source.map((s) => quoteIdent(s.fromColumn)).join(', ');
      wheres.add('($cols) = (${placeholders.join(', ')})');
    }

    // [AI Infer] mode: dropdown shows the sentinel (filterColumn==null),
    // but the actual SQL uses whatever the inferrer most recently picked.
    final col = step.filterColumn ?? step.inferredColumn;
    final pat = step.filterPattern;
    if (col != null && pat.isNotEmpty) {
      params.add(pat);
      wheres.add('(${quoteIdent(col)})::text ~* \$${params.length}');
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
    final conn = _conn();
    if (conn == null) {
      step.error = 'No connection.';
      AppState.instance.notifyChange();
      return;
    }
    if (reset) step.data = null;
    step.isLoading = true;
    step.error = null;
    AppState.instance.notifyChange();

    try {
      final catalog = SchemaCatalog(conn);
      List<ColumnInfo> allCols;
      List<String> pkCols;
      Set<String> indexed;
      try {
        allCols = await catalog.listColumns(step.schema, step.table);
      } catch (e) {
        throw StateError(
          'listColumns(${step.schema}.${step.table}) failed: $e',
        );
      }
      try {
        pkCols = await catalog.primaryKey(step.schema, step.table);
      } catch (e) {
        throw StateError('primaryKey(${step.schema}.${step.table}) failed: $e');
      }
      try {
        indexed = await catalog.indexedColumns(step.schema, step.table);
      } catch (_) {
        indexed = <String>{};
      }
      final pkInfos = allCols.where((c) => pkCols.contains(c.name)).toList();

      final base = _buildBaseWhere();
      final pager = KeysetPager(
        conn: conn,
        schema: step.schema,
        table: step.table,
        columns: pkInfos.isEmpty ? allCols : pkInfos,
        pkColumns: pkCols,
        pageSize: _kPageSize,
        baseWhere: base.where,
        baseWhereParams: base.params,
      );
      final firstPage = await pager.fetchNext();

      if (!mounted) return;
      step.columns = allCols;
      step.pkColumns = pkCols;
      step.indexedColumns = indexed;
      step.editPolicies = [
        for (final c in allCols)
          EditPolicy(
            schema: step.schema,
            table: step.table,
            pkColumns: pkCols,
            column: c.name,
            type: c.type,
            typeName: c.typeName,
            nullable: c.nullable,
            isGenerated: c.isGenerated,
            isIdentity: c.isIdentity,
            readOnly: pkCols.isEmpty || c.isGenerated || c.isIdentity,
            multiLine:
                c.type == PgType.json ||
                c.type == PgType.jsonb ||
                c.type == PgType.text,
            nullIfBlank: c.nullable,
            enumValues: c.enumValues,
          ),
      ];
      step.catalogLoaded = true;
      step.pager = pager;
      step.data = GridData(
        columns: [
          for (final c in pkInfos.isEmpty ? allCols : pkInfos)
            gridColumn(
              name: c.name,
              type: c.type,
              typeName: c.typeName,
              primaryKey: pkCols.contains(c.name),
              indexed: indexed.contains(c.name),
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

  void _onFilterColumnChanged(String? col) {
    // null is the explicit [AI Infer] sentinel — accept it.
    widget.step.filterColumn = col;
    // Drop the prior AI pick whenever the dropdown changes so the
    // fallback in _buildBaseWhere doesn't accidentally use a stale
    // target. A new Enter in AI Infer mode re-infers.
    widget.step.inferredColumn = null;
    if (widget.step.filterPattern.isNotEmpty && col != null) _load();
  }

  void _onFilterPatternChanged(String pat) {
    _filterDebounce?.cancel();
    // In [AI Infer] mode (filterColumn == null) keystrokes never auto-fire
    // — the user has to click the wand. This avoids leaking every keystroke
    // to the LLM and keeps token spend predictable.
    if (widget.step.filterColumn == null) {
      widget.step.filterPattern = pat.trim();
      return;
    }
    _filterDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      widget.step.filterPattern = pat.trim();
      _load();
    });
  }

  /// User clicked the magic-wand. Fetch 5 sample rows with all columns
  /// (the navigator's normal page only carries PK values, so we can't
  /// reuse it), pass them to the inferrer, set filterColumn to whatever
  /// it picks, and load.
  Future<void> _runAiInfer() async {
    final step = widget.step;
    final pat = _filterController.text.trim();
    if (pat.isEmpty) {
      showToast(context, 'Type a search term first.');
      return;
    }
    final cols = step.columns;
    if (cols.isEmpty) return;
    final conn = _conn();
    if (conn == null) {
      showToast(context, 'No connection.');
      return;
    }
    try {
      // Fresh SELECT * with a LIMIT — the inferrer needs values across
      // every column to discriminate, not just PK values.
      final qualified = quoteQualified(step.schema, step.table);
      final sampleRes = await conn.execute('SELECT * FROM $qualified LIMIT 5');
      final colByName = <String, int>{};
      for (var i = 0; i < sampleRes.columns.length; i++) {
        colByName[sampleRes.columns[i].name] = i;
      }
      // Realign sample rows so column[i] from `cols` lines up with
      // values at the same i — drops columns the sample didn't return
      // (shouldn't happen for SELECT * but keeps the inferrer honest).
      final alignedRows = <List<Object?>>[
        for (final row in sampleRes.rows)
          [
            for (final c in cols)
              colByName[c.name] != null ? row[colByName[c.name]!] : null,
          ],
      ];
      final picked = await RegexInferrer.infer(
        term: pat,
        columns: cols,
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
        step.filterPattern = pat;
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'AI: $e');
    }
  }

  String _rowLabel(List<Object?> rowVals, List<GridColumnSpec> cols) {
    if (cols.isEmpty) return '(row)';
    return [
      for (var i = 0; i < cols.length; i++)
        '${cols[i].name}=${_short(rowVals[i])}',
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
    for (final pk in step.pkColumns) {
      final i = data.columns.indexWhere((c) => c.name == pk);
      pkValues.add(i >= 0 ? row[i] : null);
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
    final conn = _conn();
    if (conn == null) return;
    if (!step.catalogLoaded) return;
    if (step.pkColumns.isEmpty || step.editPolicies.isEmpty) {
      showToast(context, 'Cannot insert: table has no primary key.');
      return;
    }
    final values = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => InsertRowDialog(policies: step.editPolicies),
    );
    if (values == null) return;
    try {
      final editor = CellEditor(conn);
      await editor.insertRow(
        schema: step.schema,
        table: step.table,
        editable: step.editPolicies.where((p) => !p.readOnly).toList(),
        values: values,
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
    final selectedPk = widget.tab.selectedRowPkValuesAt(widget.index);

    String? subtitle;
    final inb = step.inboundFilter;
    if (inb != null) {
      if (inb.source.length == 1) {
        subtitle =
            'where ${inb.source.first.fromColumn} = ${_short(inb.values.first)}';
      } else {
        final cols = inb.source.map((s) => s.fromColumn).join(', ');
        final vals = inb.values.map(_short).join(', ');
        subtitle = 'where ($cols) = ($vals)';
      }
    }

    final filterRow = !step.catalogLoaded
        ? null
        : Row(
            children: [
              SizedBox(
                width: 130,
                child: DropdownButtonFormField<String?>(
                  initialValue: step.filterColumn,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text(
                        '[AI Infer]',
                        style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final c in step.columns)
                      DropdownMenuItem<String?>(
                        value: c.name,
                        child: Text(
                          c.name,
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _onFilterColumnChanged,
                ),
              ),
              const SizedBox(width: 6),
              // Cap the regex field width so it doesn't balloon when the
              // column is the trailing one and absorbs the remaining
              // viewport width (see _computeWidths). LayoutBuilder lets us
              // shrink to the column's actual width when it's narrow.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LayoutBuilder(
                    builder: (_, c) => SizedBox(
                      width: c.maxWidth.clamp(0.0, 240.0),
                      child: TextField(
                        controller: _filterController,
                        decoration: const InputDecoration(
                          hintText: 'regex…',
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 14),
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 11,
                        ),
                        onChanged: _onFilterPatternChanged,
                        onSubmitted: (_) {
                          if (widget.step.filterColumn == null) {
                            _runAiInfer();
                          } else {
                            _load();
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
          padding: EdgeInsets.all(24),
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
                    padding: EdgeInsets.all(8),
                    child: Center(
                      child: SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final row = data.rows[i];
                final pkValuesForRow = <Object?>[];
                for (final pk in step.pkColumns) {
                  final j = data.columns.indexWhere((c) => c.name == pk);
                  pkValuesForRow.add(j >= 0 ? row[j] : null);
                }
                final isSel =
                    selectedPk != null && _listEq(selectedPk, pkValuesForRow);
                return InkWell(
                  onTap: () => _openRow(i),
                  child: Container(
                    color: isSel
                        ? theme.colorScheme.primaryContainer
                        : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.vpn_key,
                          size: 11,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
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
                        const Icon(Icons.chevron_right, size: 14),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (data.rows.isNotEmpty && !step.hasNextPage && !step.isLoadingMore)
            Padding(
              padding: const EdgeInsets.all(6),
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
            icon: const Icon(Icons.add, size: 16),
            onPressed: !step.catalogLoaded || step.pkColumns.isEmpty
                ? null
                : _insertRow,
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh, size: 16),
            onPressed: step.isLoading ? null : _load,
          ),
          if (widget.index > 0)
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
      filter: filterRow,
      child: body,
    );
  }
}

// ---------------------------------------------------------------------------
