import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Page;
import 'package:widgets/widgets.dart';

import '../catalog/schema_catalog.dart';
import '../connection/registry.dart';
import '../db/dml.dart';
import '../db/edit_policy.dart';
import '../db/executor.dart';
import '../db/write_rules.dart';
import '../grid/data_grid.dart';
import '../grid/row_dialog.dart';
import '../inspector/grid_with_inspector.dart';
import '../inspector/result_inspector_panel.dart';
import '../meta/charts/chart_view.dart';
import '../meta/masked_value.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../meta/named_query/named_query_tab.dart';
import '../meta/ui/action_trust.dart';
import '../meta/ui/description_tooltip.dart';
import '../meta/ui/meta_column_header.dart';
import '../meta/ui/meta_dialogs.dart';
import '../meta/ui/meta_menu.dart';
import '../navigator/navigator_tab.dart';
import '../query/cancel_token.dart';
import '../query/pager.dart';
import '../query/runner.dart';
import '../shell/app_state.dart';
import '../util/pg_errors.dart';
import '../util/sql_quote.dart';

class TableTabView extends StatefulWidget {
  final TableTab tab;
  const TableTabView({super.key, required this.tab});

  @override
  State<TableTabView> createState() => _TableTabViewState();
}

class _TableTabViewState extends State<TableTabView> {
  KeysetPager? _pager;
  Timer? _autoRefreshTimer;
  final DataGridController _gridController = DataGridController();

  /// Background fetch of the page after the one currently rendered.
  /// Non-null while a prefetch is in flight or its result is waiting to
  /// be consumed by [_loadMore]. Single-slot — the pager is not safe for
  /// concurrent fetchNext calls.
  Future<Page>? _nextPagePrefetch;

  /// Hard cap on the in-memory row buffer. A billion-row table will not
  /// fit in RAM and the grid holds every row we hand it. When the buffer
  /// exceeds this, we drop the oldest [_trimChunk] rows and adjust the
  /// scroll offset to keep the viewport stable.
  ///
  /// 50k rows × ~10 cols × ~50 bytes ≈ 25 MB — generous on desktop and
  /// large enough that ordinary up-down scrolling within a session
  /// stays inside the buffer. Scrolling further back requires Refresh
  /// or Jump-to-PK.
  static const int _maxBufferedRows = 50000;
  static const int _trimChunk = 5000;

  /// The metadata snapshot this table was last loaded under. When the
  /// metadata reloads (or "View as…" switches roles) the access decisions
  /// may change, so the table reloads.
  Object? _loadedUnder;

  void _onMetadataChanged() {
    if (!mounted) return;
    final current = MetadataCache.instance.snapshotFor(
      widget.tab.connectionId,
    );
    if (current == null || identical(current, _loadedUnder)) return;
    if (current.status != MetaLoadStatus.ready) return;
    _loadedUnder = current;
    _load();
  }

  /// Bumped by every [_load]; a load that finishes after a newer one
  /// started discards its result (older policy, older sort/filter).
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    MetadataCache.instance.addListener(_onMetadataChanged);
    _loadedUnder = widget.tab.loadedUnder;
    final current = MetadataCache.instance.snapshotFor(widget.tab.connectionId);
    if (widget.tab.data != null &&
        current != null &&
        current.status == MetaLoadStatus.ready &&
        !identical(current, widget.tab.loadedUnder)) {
      // Revisited after the policy changed: reload under the current one.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onMetadataChanged();
      });
    }
    if (widget.tab.data == null && widget.tab.error == null) {
      // Defer: _load() calls AppState.notifyChange() synchronously, which
      // would fire setState on ancestor listeners while their build is in
      // flight if we ran during initState.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    _setupAutoRefresh();
  }

  @override
  void didUpdateWidget(covariant TableTabView old) {
    super.didUpdateWidget(old);
    if (old.tab.autoRefresh != widget.tab.autoRefresh) {
      _setupAutoRefresh();
    }
  }

  @override
  void dispose() {
    MetadataCache.instance.removeListener(_onMetadataChanged);
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  void _setupAutoRefresh() {
    _autoRefreshTimer?.cancel();
    final d = widget.tab.autoRefresh.duration;
    if (d != null) {
      _autoRefreshTimer = Timer.periodic(d, (_) => _autoRefreshTick());
    }
  }

  Future<void> _autoRefreshTick() async {
    final tab = widget.tab;
    if (tab.isLoading || tab.isLoadingMore) return;
    final data = tab.data;
    if (data == null) return;
    // Refresh first page only; the user can scroll again. Preserves the
    // page-1 invariant from the plan without doing a visible-range diff.
    await _load();
  }

  DbExecutor? _conn() =>
      ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  bool _readOnly() => false;

  Future<void> _load() async {
    final conn = _conn();
    if (conn == null) {
      setState(() => widget.tab.error = 'No connection.');
      return;
    }
    final generation = ++_loadGeneration;
    final loadedUnder = MetadataCache.instance.snapshotFor(
      widget.tab.connectionId,
    );
    final token = CancelToken();
    setState(() {
      widget.tab.isLoading = true;
      widget.tab.error = null;
      widget.tab.cancelToken = token;
    });
    AppState.instance.notifyChange();
    // Any prefetch from a prior pager is now stale — drop the reference
    // and let it complete into the void. The new pager replaces _pager
    // below, so the old future's result would be discarded anyway.
    _nextPagePrefetch = null;
    try {
      final loader = TableLoader(conn, connectionReadOnly: _readOnly());
      final profile = ConnectionRegistry.instance.profileById(
        widget.tab.connectionId,
      );
      final result = await loader.loadTable(
        schema: widget.tab.schema,
        table: widget.tab.table,
        profile: profile,
        showDeleted: widget.tab.showDeleted,
        sortColumn: widget.tab.sort?.column,
        descending: widget.tab.sort?.descending ?? false,
        cancelToken: token,
        baseWhere: widget.tab.metaFilter?.where,
        baseWhereParams: widget.tab.metaFilter?.params ?? const [],
        defaultFilterTrusted: _metadataSqlTrusted(),
      );
      if (!mounted || generation != _loadGeneration) return;
      _pager = result.pager;
      widget.tab.loadedUnder = loadedUnder;
      _loadedUnder = loadedUnder;
      // First load seeds the collapsed columns from access-control
      // `default_hidden`; after that the user's choice sticks.
      widget.tab.hiddenColumns ??= {
        for (final c in result.columns)
          if (c.defaultHidden) c.name,
      };
      final newData = _gridDataFor(
        result.columns,
        result.firstRows,
        pk: result.pkColumns,
        indexed: result.indexedColumns,
      );
      setState(() {
        widget.tab.data = newData;
        widget.tab.elapsed = result.elapsed;
        widget.tab.isLoading = false;
        widget.tab.cancelToken = null;
        widget.tab.pkColumns = result.pkColumns;
        widget.tab.indexedColumns = result.indexedColumns;
        widget.tab.catalogColumns = result.columns;
        widget.tab.editPolicies = result.editPolicies;
        widget.tab.hasNextPage = !result.pager.isDone;
        widget.tab.effectiveSoftDeleteColumn = result.effectiveSoftDeleteColumn;
        widget.tab.tenantFilterApplied = result.tenantFilterApplied;
        widget.tab.tableAccess = result.tableAccess;
        widget.tab.defaultFilterApplied = result.defaultFilterApplied;
        widget.tab.defaultFilterPending = result.defaultFilterPending;
        widget.tab.hardDeleteRefusal = result.hardDeleteRefusal;
        widget.tab.deleteRefusal = result.deleteRefusal;
        widget.tab.returningList = result.returningList;
        if (widget.tab.sort == null && result.effectiveSort != null) {
          widget.tab.sort = TableSortState(
            result.effectiveSort!.column,
            result.effectiveSort!.descending,
          );
        }
      });
      // FKs are a one-time per-database query — load them lazily.
      if (widget.tab.foreignKeys.isEmpty) {
        _loadForeignKeys(conn);
      }
      // Reset the grid to the fresh column/row set. This is the only
      // place a full rebuild happens (sort change, table open, refresh).
      if (_gridController.isAttached) {
        _gridController.replaceAll(newData);
      }
      // First page is on screen; start fetching the next one in the
      // background so the user's first scroll-to-bottom resolves with
      // no network wait.
      _kickPrefetch();
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        widget.tab.error = classify(e).message;
        widget.tab.isLoading = false;
        widget.tab.cancelToken = null;
      });
    } finally {
      AppState.instance.notifyChange();
    }
  }

  GridData _gridDataFor(
    List<ColumnInfo> columns,
    List<List<Object?>> rows, {
    required List<String> pk,
    required Set<String> indexed,
  }) {
    final hidden = widget.tab.hiddenColumns ?? const <String>{};
    return GridData(
      columns: [
        for (final c in columns)
          gridColumn(
            name: c.name,
            type: c.type,
            typeName: c.typeName,
            primaryKey: pk.contains(c.name),
            indexed: indexed.contains(c.name),
            hidden: hidden.contains(c.name),
            marker: c.isMasked ? '••' : null,
          ),
      ],
      rows: rows,
    );
  }

  /// Fire a non-awaited fetch for the page after the current tail and
  /// stash the Future. The pager isn't safe for concurrent fetchNext,
  /// so this is a no-op if one is already in flight or its result is
  /// still waiting to be consumed.
  void _kickPrefetch() {
    if (!mounted) return;
    final pager = _pager;
    if (pager == null || pager.isDone) return;
    if (_nextPagePrefetch != null) return;
    final token = widget.tab.cancelToken ?? CancelToken();
    widget.tab.cancelToken = token;
    _nextPagePrefetch = pager.fetchNext(cancelToken: token);
  }

  Future<void> _loadMore() async {
    if (_pager == null || _pager!.isDone) return;
    if (widget.tab.isLoadingMore) return;
    final token = widget.tab.cancelToken ?? CancelToken();
    widget.tab.cancelToken = token;
    widget.tab.isLoadingMore = true;
    AppState.instance.notifyChange();
    try {
      // Consume an in-flight prefetch if we have one; otherwise issue
      // the fetch synchronously. Either way only one fetchNext is in
      // flight on the pager at a time.
      final pendingFuture =
          _nextPagePrefetch ?? _pager!.fetchNext(cancelToken: token);
      _nextPagePrefetch = null;
      final page = await pendingFuture;
      if (!mounted) return;
      final existing = widget.tab.data;
      if (existing == null) return;
      // Mutate the row buffer in place and notify the grid via the
      // controller so it does O(delta) work instead of rebuilding all
      // accumulated rows. Without this, scrolling N pages is O(N²)
      // and the in-memory buffer grows unbounded.
      existing.rows.addAll(page.rows);
      _gridController.appendRows(page.rows);

      // Enforce sliding window. The grid holds every row we hand it,
      // so an audit table with billions of rows would collapse memory
      // without a cap. Trim in chunks of at least `_trimChunk` so we
      // are not paying the trim cost every page.
      if (existing.rows.length > _maxBufferedRows) {
        final overflow = existing.rows.length - _maxBufferedRows;
        final actual = math.max(overflow, _trimChunk);
        existing.rows.removeRange(0, actual);
        _gridController.removeFirstRows(actual);
      }

      setState(() {
        widget.tab.hasNextPage = !_pager!.isDone;
        widget.tab.isLoadingMore = false;
      });
      // Start fetching the page after the one we just appended so the
      // next scroll-to-bottom is instant.
      _kickPrefetch();
    } catch (_) {
      if (!mounted) return;
      // The failed fetch may have been the prefetch we adopted — clear
      // the slot so the next user attempt issues a fresh request.
      _nextPagePrefetch = null;
      setState(() => widget.tab.isLoadingMore = false);
    }
    AppState.instance.notifyChange();
  }

  Future<void> _onSort(GridSortEvent event) async {
    final masked = widget.tab.catalogColumns.any(
      (c) => c.name == event.column && c.isMasked,
    );
    if (masked) {
      showToast(
        context,
        '"${event.column}" is masked for you, so it cannot be sorted.',
      );
      return;
    }
    final indexed = widget.tab.indexedColumns;
    final isFast =
        indexed.contains(event.column) ||
        widget.tab.pkColumns.contains(event.column);
    if (!isFast) {
      final ok = await confirmDialog(
        context,
        title: 'Sort on unindexed column?',
        message:
            'Column "${event.column}" is not indexed. '
            'Sorting may be slow on large tables.',
        confirmLabel: 'Continue',
      );
      if (!ok) return;
    }
    setState(() {
      widget.tab.sort = TableSortState(event.column, event.descending);
    });
    await _load();
  }

  Future<void> _onCellEdit(GridEditEvent event) async {
    final tab = widget.tab;
    final data = tab.data;
    if (data == null) return;
    if (_readOnly()) {
      showToast(context, 'This connection is read-only.');
      return;
    }
    final policy = tab.editPolicies.firstWhere(
      (p) => p.column == event.column,
      orElse: () => EditPolicy(
        schema: tab.schema,
        table: tab.table,
        pkColumns: tab.pkColumns,
        column: event.column,
        type: data.columns.firstWhere((c) => c.name == event.column).pgType,
        typeName: data.columns
            .firstWhere((c) => c.name == event.column)
            .typeName,
        nullable: true,
        isGenerated: false,
        isIdentity: false,
        readOnly: true,
        multiLine: false,
        nullIfBlank: true,
      ),
    );
    if (policy.readOnly) {
      if (policy.readOnlyReason != null) {
        showToast(context, policy.readOnlyReason!);
      }
      return;
    }
    final invalid = policy.validate(event.newValueRaw);
    if (invalid != null) {
      showToast(context, invalid);
      return;
    }

    final conn = _conn();
    if (conn == null) return;

    final rowValues = data.rows[event.rowIdx];
    final colIdx = data.columns.indexWhere((c) => c.name == event.column);
    final oldValue = rowValues[colIdx];

    final pkValues = <String, Object?>{};
    for (final pk in policy.pkColumns) {
      final idx = data.columns.indexWhere((c) => c.name == pk);
      pkValues[pk] = rowValues[idx];
    }
    try {
      final editor = CellEditor(conn);
      final result = await editor.updateCell(
        policy: policy,
        pkValues: pkValues,
        oldValue: oldValue,
        newValueRaw: event.newValueRaw,
      );
      if (!mounted) return;
      if (result.affectedRows == 0) {
        showToast(
          context,
          'Value changed since you loaded it. Refreshing row.',
        );
        await _load();
        return;
      }
      // Mutate the row in place. Pluto already updated its own cell
      // when the user committed the edit; only re-push if the server
      // coerced the value to something different. `parseValue` always
      // allocates fresh, so identity comparison would fire every edit —
      // use value equality.
      data.rows[event.rowIdx][colIdx] = result.newValue;
      if (result.newValue != event.newValueRaw) {
        _gridController.updateCell(event.rowIdx, event.column, result.newValue);
      }
    } catch (e) {
      if (!mounted) return;
      await _showWriteError(_conn(), 'Update', e);
      await _load();
    }
  }

  /// Surface a write error. For CHECK-violations (code 23514) we look
  /// up the constraint definition so the user sees *what* rule fired
  /// instead of just its name. Best-effort — falls back to the plain
  /// classified message when the catalog lookup misses or errors.
  Future<void> _showWriteError(
    DbExecutor? conn,
    String verb,
    Object error,
  ) async {
    final classified = classify(error);
    var message = '$verb failed: ${classified.message}';
    if (classified.kind == PgErrorKind.checkViolation &&
        classified.constraintName != null &&
        conn != null) {
      try {
        final def = await SchemaCatalog(
          conn,
        ).lookupCheckDefinition(classified.constraintName!);
        if (def != null && def.isNotEmpty) {
          message = '$message\n→ $def';
        }
      } catch (_) {
        // Best-effort enrichment — fall back to the base message.
      }
    }
    if (!mounted) return;
    showToast(context, message);
  }

  Future<void> _deleteRow(int rowIdx) async {
    final tab = widget.tab;
    final data = tab.data;
    if (data == null) return;
    if (tab.pkColumns.isEmpty) {
      showToast(context, 'Cannot delete: table has no primary key.');
      return;
    }
    if (_readOnly()) {
      showToast(context, 'This connection is read-only.');
      return;
    }
    final conn = _conn();
    if (conn == null) return;

    final rowValues = data.rows[rowIdx];
    final pkValues = <String, Object?>{};
    final pkSummary = <String>[];
    for (final pk in tab.pkColumns) {
      final idx = data.columns.indexWhere((c) => c.name == pk);
      pkValues[pk] = rowValues[idx];
      pkSummary.add('$pk = ${rowValues[idx]}');
    }
    // Shared with the Navigator: access, metadata `danger`, masked keys.
    final refusal = writeRulesFor(
      conn,
      schema: tab.schema,
      table: tab.table,
      columns: tab.catalogColumns,
      pkColumns: tab.pkColumns,
      profile: ConnectionRegistry.instance.profileById(tab.connectionId),
    ).whyNoDelete(pkColumns: tab.pkColumns, pkValues: pkValues);
    if (refusal != null) {
      showToast(context, refusal);
      return;
    }
    final softCol = tab.effectiveSoftDeleteColumn;
    final ok = await confirmDialog(
      context,
      title: softCol == null ? 'Delete row?' : 'Soft-delete row?',
      message: softCol == null
          ? 'WHERE ${pkSummary.join(' AND ')}'
          : 'UPDATE ${tab.schema}.${tab.table} SET $softCol = now()\n'
                'WHERE ${pkSummary.join(' AND ')}',
      confirmLabel: softCol == null ? 'Delete' : 'Soft-delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      final editor = CellEditor(conn);
      final affected = softCol == null
          ? await editor.deleteRow(
              schema: tab.schema,
              table: tab.table,
              pkColumns: tab.pkColumns,
              pkValues: pkValues,
            )
          : await editor.softDeleteRow(
              schema: tab.schema,
              table: tab.table,
              pkColumns: tab.pkColumns,
              pkValues: pkValues,
              deletedColumn: softCol,
            );
      if (!mounted) return;
      if (affected == 0) {
        showToast(context, 'Row already gone.');
      }
      // When "Show deleted" is on, soft-deleted rows stay visible (just
      // with a stamped tombstone). Remove from the grid only when the
      // filter would have hidden them — hard delete or soft delete with
      // showDeleted off.
      if (softCol == null || !tab.showDeleted) {
        data.rows.removeAt(rowIdx);
        _gridController.removeRowAt(rowIdx);
      } else {
        // Soft-deleted in place — refresh just this row so the grid
        // shows the new deleted_at timestamp.
        await _load();
      }
    } catch (e) {
      if (!mounted) return;
      await _showWriteError(
        _conn(),
        softCol == null ? 'Delete' : 'Soft-delete',
        e,
      );
    }
  }

  Future<void> _insertRow() async {
    final tab = widget.tab;
    if (_readOnly()) {
      showToast(context, 'This connection is read-only.');
      return;
    }
    if (tab.editPolicies.isEmpty) return;
    final insertConn = _conn();
    if (insertConn == null) return;
    final insertRefusal = writeRulesFor(
      insertConn,
      schema: tab.schema,
      table: tab.table,
      columns: tab.catalogColumns,
      pkColumns: tab.pkColumns,
    ).whyNoInsert(pkColumns: tab.pkColumns);
    if (insertRefusal != null) {
      showToast(context, insertRefusal);
      return;
    }
    final values = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => InsertRowDialog(policies: tab.editPolicies),
    );
    if (values == null) return;
    final conn = _conn();
    if (conn == null) return;
    try {
      final editor = CellEditor(conn);
      final returned = await editor.insertRow(
        schema: tab.schema,
        table: tab.table,
        editable: tab.editPolicies.where((p) => !p.readOnly).toList(),
        values: values,
        returning: tab.returningList,
      );
      final inserted = maskInsertedRow(returned, {
        for (var i = 0; i < tab.catalogColumns.length; i++)
          if (tab.catalogColumns[i].isMasked) i,
      });
      if (!mounted) return;
      final data = tab.data;
      if (data != null) {
        data.rows.insert(0, inserted);
        _gridController.prependRow(inserted);
      }
    } catch (e) {
      if (!mounted) return;
      await _showWriteError(_conn(), 'Insert', e);
    }
  }

  Future<void> _exactCount() async {
    final conn = _conn();
    if (conn == null) return;
    final tab = widget.tab;
    setState(() => tab.exactRows = null);
    try {
      final catalog = SchemaCatalog(conn);
      final count = await catalog.exactCount(tab.schema, tab.table);
      if (!mounted) return;
      setState(() {
        tab.exactRows = count;
        tab.estimatedRows = count;
      });
      AppState.instance.notifyChange();
    } catch (e) {
      if (!mounted) return;
      showToast(context, classify(e).message);
    }
  }

  Future<void> _loadForeignKeys(DbExecutor conn) async {
    try {
      final fks = await SchemaCatalog(conn).listForeignKeys();
      if (!mounted) return;
      setState(() => widget.tab.foreignKeys = fks);
      AppState.instance.notifyChange();
    } catch (_) {
      // FK loading is best-effort; the grid renders fine without it.
    }
  }

  void _followLink(ForeignKey fk, bool incoming) {
    final data = widget.tab.data;
    final selectedIdx = widget.tab.selectedRowIndex;
    if (data == null || selectedIdx == null) return;
    final row = data.rows[selectedIdx];

    if (incoming) {
      // Inbound: spin up a query tab that selects the rows pointing at
      // this row. Self-contained SQL (literal embedded) so Re-run from
      // the editor works without param-binding context.
      final pkIdx = data.columns.indexWhere((c) => c.name == fk.toColumn);
      if (pkIdx < 0) return;
      final pkValue = row[pkIdx];
      if (pkValue is MaskedValue) {
        showToast(
          context,
          'That value is masked for you, so it can\'t be followed.',
        );
        return;
      }
      final conn = _conn();
      if (conn == null) return;
      final title =
          '${fk.fromTable} where ${fk.fromColumn} = ${_shortValue(pkValue)}';
      final policy = MetadataCache.instance.policyForExecutor(conn);
      if (!policy.can(Capability.query)) {
        // No free SQL for this role: show the referencing rows read-only,
        // with the same column access as the referencing table.
        AppState.instance.openTab(
          NamedQueryTab.adHoc(
            connectionId: widget.tab.connectionId,
            label: title,
            sql:
                'SELECT * FROM ${quoteQualified(fk.fromSchema, fk.fromTable)} '
                'WHERE ${quoteIdent(fk.fromColumn)} = @ref',
            boundParams: {'ref': pkValue},
            accessTable: (schema: fk.fromSchema, table: fk.fromTable),
            fromMetadata: false,
          ),
        );
        return;
      }
      final sql =
          'SELECT * FROM ${quoteQualified(fk.fromSchema, fk.fromTable)}\n'
          'WHERE ${quoteIdent(fk.fromColumn)} = ${quoteLiteral(pkValue)};';
      AppState.instance.newQueryTab(
        widget.tab.connectionId,
        initialSql: sql,
        title: title,
        autoRun: true,
      );
    } else {
      // Outbound: jump to the single linked row via the Navigator's
      // detail step (one row, FK chips ready to follow further).
      final fromIdx = data.columns.indexWhere((c) => c.name == fk.fromColumn);
      if (fromIdx < 0) return;
      if (row[fromIdx] is MaskedValue) {
        showToast(
          context,
          'That value is masked for you, so it can\'t be followed.',
        );
        return;
      }
      final tab = NavigatorTab(connectionId: widget.tab.connectionId);
      tab.steps.add(
        RowDetailStep(
          schema: fk.toSchema,
          table: fk.toTable,
          pkColumns: [fk.toColumn],
          pkValues: [row[fromIdx]],
        ),
      );
      AppState.instance.openTab(tab);
    }
  }

  String _shortValue(Object? v) {
    if (v == null) return 'NULL';
    final s = v.toString();
    return s.length <= 24 ? s : '${s.substring(0, 21)}…';
  }

  Future<void> _saveCellFromInspector(EditPolicy policy, Object? newRaw) async {
    final tab = widget.tab;
    final data = tab.data;
    final idx = tab.selectedRowIndex;
    if (data == null || idx == null) return;
    final colIdx = data.columns.indexWhere((c) => c.name == policy.column);
    if (colIdx < 0) return;
    final oldValue = data.rows[idx][colIdx];
    await _onCellEdit(GridEditEvent(idx, policy.column, oldValue, newRaw));
  }

  bool _metadataSqlTrusted() {
    final snapshot = MetadataCache.instance.snapshotFor(
      widget.tab.connectionId,
    );
    if (snapshot == null) return false;
    return MetaTrust.isTrusted(
      widget.tab.connectionId,
      snapshot.index,
      TrustScope.read,
    );
  }

  Future<void> _trustDefaultFilter() async {
    final ok = await ensureTrusted(
      context,
      widget.tab.connectionId,
      TrustScope.read,
    );
    if (ok && mounted) await _load();
  }

  Map<String, DisplaySpec> _displayByColumn() {
    final snapshot = MetadataCache.instance.snapshotFor(
      widget.tab.connectionId,
    );
    if (snapshot == null) return const {};
    return {
      for (final c in widget.tab.catalogColumns)
        c.name: snapshot.index.displayColumn(
          widget.tab.schema,
          widget.tab.table,
          c.name,
        ),
    };
  }

  Map<String, Object?> _rowMap(int rowIdx) {
    final data = widget.tab.data;
    if (data == null || rowIdx < 0 || rowIdx >= data.rows.length) {
      return const {};
    }
    final row = data.rows[rowIdx];
    return {
      for (var i = 0; i < data.columns.length; i++)
        data.columns[i].name: row[i],
    };
  }

  List<GridMenuEntry> _menuExtras(
    int rowIdx,
    int columnIdx,
    List<int> selectedRows,
  ) {
    final tab = widget.tab;
    final data = tab.data;
    if (data == null) return const [];
    final column = data.columns[columnIdx];
    final row = _rowMap(rowIdx);
    final click = MetaClickContext(
      connectionId: tab.connectionId,
      schema: tab.schema,
      table: tab.table,
      row: row,
      pkColumns: tab.pkColumns,
      column: column.name,
      columnType: column.pgType,
      cell: row[column.name],
      selection: [for (final r in selectedRows) _rowMap(r)],
    );
    return [
      for (final item in buildMetaMenuItems(context, click))
        GridMenuEntry(
          label: item.label,
          icon: item.icon,
          enabled: item.enabled,
          disabledReason: item.disabledReason,
          onSelected: item.onSelected,
          startsGroup: item.startsGroup,
        ),
      GridMenuEntry(
        label: 'Hide column "${column.name}"',
        icon: Icons.visibility_off_outlined,
        startsGroup: true,
        onSelected: () => _setHidden({
          ...?tab.hiddenColumns,
          column.name,
        }),
      ),
    ];
  }

  void _setHidden(Set<String> hidden) {
    final tab = widget.tab;
    setState(() {
      tab.hiddenColumns = hidden;
      // Keep the column specs in step: a remounted grid (switching tabs and
      // back) reads its hidden columns from them, not from the controller.
      final data = tab.data;
      if (data != null) {
        tab.data = GridData(
          columns: [
            for (final c in data.columns)
              gridColumn(
                name: c.name,
                type: c.pgType,
                typeName: c.typeName,
                primaryKey: c.primaryKey,
                indexed: c.indexed,
                defaultWidth: c.defaultWidth,
                hidden: hidden.contains(c.name),
                tooltip: c.tooltip,
                marker: c.marker,
              ),
          ],
          rows: data.rows,
        );
      }
    });
    _gridController.setHiddenColumns(hidden);
  }

  Future<void> _pickColumns() async {
    final tab = widget.tab;
    final hidden = {...?tab.hiddenColumns};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AppFormDialog(
          title: 'Columns of ${tab.table}',
          width: 380,
          height: 480,
          submitLabel: 'Apply',
          onSubmit: () => Navigator.of(ctx).pop(hidden),
          content: Column(
            children: [
              for (final c in tab.catalogColumns)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: !hidden.contains(c.name),
                  title: Text(c.name),
                  subtitle: c.defaultHidden
                      ? const Text('hidden by default')
                      : null,
                  onChanged: (v) => setDialogState(() {
                    if (v ?? false) {
                      hidden.remove(c.name);
                    } else {
                      hidden.add(c.name);
                    }
                  }),
                ),
            ],
          ),
        ),
      ),
    );
    if (result != null) _setHidden(result);
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final readOnly = _readOnly();
    final snapshot = MetadataCache.instance.snapshotFor(tab.connectionId);
    final charts =
        snapshot?.index.chartsForTable(tab.schema, tab.table) ??
        const <ChartSpec>[];
    final executor = _conn();
    final noPk = tab.pkColumns.isEmpty && tab.data != null;
    final appState = AppState.instance;
    final showInspector = !appState.propertyInspectorCollapsed;

    final gridArea = Column(
      children: [
        TableTabHeader(
          tab: tab,
          onRefresh: _load,
          onInsert: _insertRow,
          onExactCount: _exactCount,
          onAutoRefreshChanged: (v) {
            setState(() => widget.tab.autoRefresh = v);
            AppState.instance.notifyChange();
          },
          onViewModeChanged: (v) {
            setState(() => widget.tab.viewMode = v);
            AppState.instance.notifyChange();
          },
          onToggleInspector: () {
            AppState.instance.togglePropertyInspector();
          },
          onToggleShowDeleted: () {
            setState(() => widget.tab.showDeleted = !widget.tab.showDeleted);
            _load();
          },
          inspectorCollapsed: !showInspector,
          readOnly: readOnly,
          hasCharts: charts.isNotEmpty,
          onToggleCharts: () {
            setState(() => tab.chartsOpen = !tab.chartsOpen);
            AppState.instance.notifyChange();
          },
          onPickColumns: _pickColumns,
          onTrustDefaultFilter: _trustDefaultFilter,
          tableDescription: snapshot?.index
              .describeTable(tab.schema, tab.table)
              .toMarkdown(),
        ),
        if (tab.chartsOpen && charts.isNotEmpty && executor != null)
          SizedBox(
            height: 236,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              children: [
                for (final c in charts)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 420,
                      child: MetaChartCard(
                        chart: c,
                        executor: executor,
                        autoRun: tab.estimatedRows < kAutoRunChartRowLimit,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (noPk)
          const AppBanner(
            message:
                'This table has no primary key. Editing, insert, '
                'and delete are disabled.',
            severity: BannerSeverity.info,
          )
        else if (!readOnly)
          const AppBanner(
            message:
                'Double-click a cell to edit. '
                'Right-click a row to delete.',
            dense: true,
          ),
        const Divider(height: 1),
        Expanded(
          child: DataGrid(
            key: ValueKey(tab.id),
            data: tab.data ?? const GridData(columns: [], rows: []),
            isLoading: tab.isLoading || tab.isLoadingMore,
            error: tab.error,
            editPolicies: tab.editPolicies,
            controller: _gridController,
            onCellEdit: noPk ? null : _onCellEdit,
            onDeleteRow: noPk ? null : _deleteRow,
            onSort: _onSort,
            onLoadMore: _loadMore,
            onRowSelected: (idx) {
              if (widget.tab.selectedRowIndex == idx) return;
              setState(() => widget.tab.selectedRowIndex = idx);
              AppState.instance.notifyChange();
            },
            hasMore: tab.hasNextPage,
            viewMode: tab.viewMode,
            foreignKeys: tab.foreignKeys,
            schema: tab.schema,
            table: tab.table,
            onFollowLink: _followLink,
            displayByColumn: _displayByColumn(),
            contextMenuExtras: _menuExtras,
            headerBuilder: (context, columnIdx, header) =>
                MetaColumnHeader.forTable(
                  connectionId: tab.connectionId,
                  schema: tab.schema,
                  table: tab.table,
                  column: tab.data!.columns[columnIdx].name,
                  columnType: tab.data!.columns[columnIdx].pgType,
                  child: header,
                ),
          ),
        ),
      ],
    );

    return GridWithInspector(
      grid: gridArea,
      inspector: ResultInspectorPanel(
        schema: tab.schema,
        table: tab.table,
        data: tab.data,
        selectedRowIndex: tab.selectedRowIndex,
        catalogColumns: tab.catalogColumns,
        editPolicies: tab.editPolicies,
        pkColumns: tab.pkColumns,
        foreignKeys: tab.foreignKeys,
        connectionId: tab.connectionId,
        onSave: _saveCellFromInspector,
        onFollowLink: _followLink,
      ),
    );
  }
}

class TableTabHeader extends StatelessWidget {
  final TableTab tab;
  final VoidCallback onRefresh;
  final VoidCallback onInsert;
  final VoidCallback onExactCount;
  final ValueChanged<AutoRefreshInterval> onAutoRefreshChanged;
  final ValueChanged<GridViewMode> onViewModeChanged;
  final VoidCallback onToggleInspector;
  final VoidCallback onToggleShowDeleted;
  final bool inspectorCollapsed;
  final bool readOnly;
  final bool hasCharts;
  final VoidCallback onToggleCharts;
  final VoidCallback onPickColumns;
  final VoidCallback onTrustDefaultFilter;

  /// Metadata description of the table, shown as the title's tooltip.
  final String? tableDescription;

  const TableTabHeader({
    super.key,
    required this.tab,
    required this.onRefresh,
    required this.onInsert,
    required this.onExactCount,
    required this.onAutoRefreshChanged,
    required this.onViewModeChanged,
    required this.onToggleInspector,
    required this.onToggleShowDeleted,
    required this.inspectorCollapsed,
    required this.readOnly,
    required this.hasCharts,
    required this.onToggleCharts,
    required this.onPickColumns,
    required this.onTrustDefaultFilter,
    this.tableDescription,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PanelHeader(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      titleIcon: Icons.table_chart_outlined,
      title: tab.title,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if ((tableDescription ?? '').isNotEmpty) ...[
            DescriptionTooltip(
              markdown: tableDescription!,
              child: Icon(Icons.info_outline, size: 14, color: theme.hintColor),
            ),
            const SizedBox(width: 8),
          ],
          if (tab.tableAccess.level != AccessLevel.full) ...[
            _Badge(
              icon: Icons.shield_outlined,
              label: tab.tableAccess.level.name,
              tooltip: tab.tableAccess.reason,
              color: theme.colorScheme.secondaryContainer,
            ),
            const SizedBox(width: 8),
          ],
          if (tab.metaFilter != null) ...[
            _Badge(
              icon: Icons.filter_alt,
              label: tab.metaFilter!.label,
              tooltip: tab.metaFilter!.where,
              color: theme.colorScheme.tertiaryContainer,
            ),
            const SizedBox(width: 8),
          ],
          if (tab.defaultFilterPending) ...[
            InkWell(
              onTap: onTrustDefaultFilter,
              child: _Badge(
                icon: Icons.filter_list_off,
                label: 'default filter off',
                tooltip:
                    'The metadata defines a default filter for this table. '
                    'It applies once you trust this connection\'s metadata '
                    'SQL — click to review it.',
                color: theme.colorScheme.errorContainer,
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (tab.defaultFilterApplied != null) ...[
            _Badge(
              icon: Icons.filter_list,
              label: 'default filter',
              tooltip: 'Metadata filter: ${tab.defaultFilterApplied}',
              color: theme.colorScheme.tertiaryContainer,
            ),
            const SizedBox(width: 8),
          ],
          if (tab.tenantFilterApplied) ...[
            Tooltip(
              message:
                  'A profile-level tenant filter is applied to this '
                  'table. Edit the connection to change it.',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.filter_alt_outlined, size: 12),
                    const SizedBox(width: 3),
                    Text('tenant', style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (tab.effectiveSoftDeleteColumn != null) ...[
            Tooltip(
              message: tab.showDeleted
                  ? 'Showing soft-deleted rows. Click to hide them.'
                  : 'Hiding soft-deleted rows (${tab.effectiveSoftDeleteColumn} IS NULL). '
                        'Click to include them.',
              child: InkWell(
                onTap: onToggleShowDeleted,
                borderRadius: BorderRadius.circular(3),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: tab.showDeleted
                        ? theme.colorScheme.errorContainer
                        : theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        tab.showDeleted
                            ? Icons.visibility
                            : Icons.visibility_off,
                        size: 12,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        tab.showDeleted ? 'deleted shown' : 'deleted hidden',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (tab.sort != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                'sort: ${tab.sort!.column} ${tab.sort!.descending ? "↓" : "↑"}',
                style: theme.textTheme.labelSmall,
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (tab.exactRows == null)
            TextButton.icon(
              icon: const Icon(Icons.numbers, size: 16),
              label: const Text('Exact count'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: onExactCount,
            ),
          DropdownButton<GridViewMode>(
            value: tab.viewMode,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final v in GridViewMode.values)
                DropdownMenuItem(
                  value: v,
                  child: Text('View: ${v.label}'),
                ),
            ],
            onChanged: (v) {
              if (v != null) onViewModeChanged(v);
            },
          ),
          const SizedBox(width: 8),
          DropdownButton<AutoRefreshInterval>(
            value: tab.autoRefresh,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final v in AutoRefreshInterval.values)
                DropdownMenuItem(
                  value: v,
                  child: Text('Auto: ${v.label}'),
                ),
            ],
            onChanged: (v) {
              if (v != null) onAutoRefreshChanged(v);
            },
          ),
          IconButton(
            tooltip: 'Columns…',
            icon: const Icon(Icons.view_column_outlined, size: 18),
            onPressed: onPickColumns,
          ),
          if (hasCharts)
            IconButton(
              tooltip: tab.chartsOpen ? 'Hide charts' : 'Show charts',
              icon: Icon(
                tab.chartsOpen
                    ? Icons.insert_chart
                    : Icons.insert_chart_outlined,
                size: 18,
              ),
              onPressed: onToggleCharts,
            ),
          IconButton(
            tooltip: 'Insert row',
            icon: const Icon(Icons.add_circle_outline, size: 18),
            onPressed:
                (readOnly ||
                    tab.isLoading ||
                    !tab.tableAccess.level.atLeast(AccessLevel.full))
                ? null
                : onInsert,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: tab.isLoading ? null : onRefresh,
          ),
          IconButton(
            tooltip: inspectorCollapsed
                ? 'Show row inspector'
                : 'Hide row inspector',
            icon: Icon(
              inspectorCollapsed
                  ? Icons.view_sidebar_outlined
                  : Icons.view_sidebar,
              size: 18,
            ),
            onPressed: onToggleInspector,
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final Color color;
  const _Badge({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12),
            const SizedBox(width: 3),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
