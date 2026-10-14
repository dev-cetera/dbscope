import 'dart:async';

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../../connection/registry.dart';
import '../../grid/data_grid.dart';
import '../../inspector/grid_with_inspector.dart';
import '../../inspector/result_inspector_panel.dart';
import '../../query/cancel_token.dart';
import '../../query/runner.dart';
import '../../shell/app_state.dart';
import '../../util/listenable_state_mixin.dart';
import '../../util/pg_errors.dart';
import '../access_policy.dart';
import '../action_binding.dart';
import '../charts/chart_view.dart';
import '../masked_value.dart';
import '../meta_cache.dart';
import '../meta_models.dart';
import '../ui/action_trust.dart';
import '../ui/meta_column_header.dart';
import '../ui/meta_dialogs.dart';
import '../ui/meta_menu.dart';
import 'named_query_tab.dart';

class NamedQueryView extends StatefulWidget {
  const NamedQueryView({super.key, required this.tab});
  final NamedQueryTab tab;

  @override
  State<NamedQueryView> createState() => _NamedQueryViewState();
}

class _NamedQueryViewState extends State<NamedQueryView>
    with ListenableStateMixin {
  @override
  List<Listenable> get listenables => [MetadataCache.instance];

  final Map<String, TextEditingController> _inputControllers = {};

  NamedQueryTab get tab => widget.tab;

  MetaSnapshot? get _snapshot =>
      MetadataCache.instance.snapshotFor(tab.connectionId);

  NamedQuerySpec? get _spec {
    final id = tab.queryId;
    return id == null ? null : _snapshot?.index.queryById(id);
  }

  @override
  void initState() {
    super.initState();
    final id = tab.queryId;
    final allowed =
        id == null || (_snapshot?.policy.forQuery(id).canSeeValues ?? true);
    if (tab.autoRun && allowed && (_spec?.inputs.isEmpty ?? true)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_run());
      });
    }
    tab.autoRun = false;
  }

  @override
  void dispose() {
    for (final controller in _inputControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(ActionInput input) =>
      _inputControllers.putIfAbsent(
        input.name,
        () => TextEditingController(text: tab.inputValues[input.name] ?? ''),
      );

  AccessDecision _columnAccess(String column) {
    final snapshot = _snapshot;
    if (snapshot == null) return AccessDecision.unrestricted;
    final id = tab.queryId;
    if (id != null) return snapshot.policy.forQueryColumn(id, column);
    final table = tab.accessTable;
    if (table != null) {
      return snapshot.policy.forColumn(table.schema, table.table, column);
    }
    return AccessDecision.unrestricted;
  }

  Future<void> _run() async {
    final executor = ConnectionRegistry.instance.connectionFor(
      tab.connectionId,
    );
    if (executor == null) {
      setState(() => tab.error = 'Not connected.');
      return;
    }
    final spec = _spec;
    final sql = spec?.sql ?? tab.sql;
    if (sql.trim().isEmpty) {
      setState(
        () => tab.error = 'This query no longer exists in the metadata.',
      );
      return;
    }
    for (final input in spec?.inputs ?? const <ActionInput>[]) {
      tab.inputValues[input.name] = _controllerFor(input).text;
    }
    final inputs = <String, Object?>{};
    for (final input in spec?.inputs ?? const <ActionInput>[]) {
      final raw = tab.inputValues[input.name] ?? '';
      if (input.type == 'number') {
        final number = num.tryParse(raw.trim());
        if (number == null) {
          setState(() => tab.error = '"${input.prompt}" must be a number.');
          return;
        }
        inputs[input.name] = number;
      } else {
        inputs[input.name] = raw;
      }
    }
    final fromInputs = bindSql(sql, BindingContext(inputs: inputs));
    final named = {...fromInputs.named, ...tab.boundParams};
    final missing = [
      for (final name in findPlaceholders(fromInputs.sql))
        if (!named.containsKey(name)) name,
    ];
    if (missing.isNotEmpty) {
      setState(() => tab.error = 'Fill in: ${missing.join(', ')}');
      return;
    }

    final trusted =
        !tab.fromMetadata ||
        await ensureTrusted(context, tab.connectionId, TrustScope.read);
    if (!mounted) return;
    if (!trusted) {
      setState(
        () => tab.error =
            "This query comes from the connection's metadata. Trust its "
            'metadata SQL to run it.',
      );
      return;
    }
    final token = CancelToken();
    setState(() {
      tab.isLoading = true;
      tab.error = null;
      tab.cancelToken = token;
    });
    AppState.instance.notifyChange();
    try {
      final raw =
          await QueryRunner(
            executor,
          ).runSql(
            fromInputs.sql,
            named: named,
            cancelToken: token,
            readOnly: tab.fromMetadata,
          );
      final result = applyColumnAccess(raw, _columnAccess);
      if (!mounted) return;
      setState(() {
        tab.data = _decorate(result.data);
        tab.elapsed = result.elapsed;
        tab.truncated = result.truncated;
        tab.isLoading = false;
        tab.cancelToken = null;
        tab.selectedRowIndex = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.error = classify(e).message;
        tab.isLoading = false;
        tab.cancelToken = null;
      });
    } finally {
      AppState.instance.notifyChange();
    }
  }

  /// Column headers that explain themselves (null without a query id).
  Widget Function(BuildContext, int, Widget)? _headerBuilder() {
    final queryId = tab.queryId;
    if (queryId == null) return null;
    return (context, columnIndex, header) => MetaColumnHeader.forQuery(
      connectionId: tab.connectionId,
      queryId: queryId,
      column: tab.data!.columns[columnIndex].name,
      columnType: tab.data!.columns[columnIndex].pgType,
      child: header,
    );
  }

  /// Adds masked markers. (Descriptions come from [MetaColumnHeader].)
  GridData _decorate(GridData data) {
    return GridData(
      columns: [
        for (var i = 0; i < data.columns.length; i++)
          gridColumn(
            name: data.columns[i].name,
            type: data.columns[i].pgType,
            typeName: data.columns[i].typeName,
            marker: data.rows.isNotEmpty && data.rows.first[i] is MaskedValue
                ? '••'
                : null,
          ),
      ],
      rows: data.rows,
    );
  }

  Map<String, DisplaySpec> _displayByColumn() {
    final id = tab.queryId;
    final index = _snapshot?.index;
    final data = tab.data;
    if (id == null || index == null || data == null) return const {};
    return {
      for (final column in data.columns)
        column.name: index.displayQueryColumn(id, column.name),
    };
  }

  List<GridMenuEntry> _menuExtras(
    int rowIndex,
    int columnIndex,
    List<int> selectedRows,
  ) {
    final data = tab.data;
    if (data == null || rowIndex >= data.rows.length) return const [];
    final row = data.rows[rowIndex];
    final column = data.columns[columnIndex];
    final click = MetaClickContext(
      connectionId: tab.connectionId,
      queryId: tab.queryId,
      row: {
        for (var i = 0; i < data.columns.length; i++)
          data.columns[i].name: row[i],
      },
      column: column.name,
      columnType: column.pgType,
      cell: row[columnIndex],
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final id = tab.queryId;
    if (id != null && snapshot != null) {
      final access = snapshot.policy.forQuery(id);
      if (!access.canSeeValues) {
        return EmptyState(
          icon: Icons.lock_outline,
          message: 'You cannot run this query.\n${access.reason}',
        );
      }
    }
    final spec = _spec;
    final charts = id == null || snapshot == null
        ? const <ChartSpec>[]
        : snapshot.index.chartsForQuery(id);
    final executor = ConnectionRegistry.instance.connectionFor(
      tab.connectionId,
    );
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          titleIcon: Icons.manage_search,
          title: spec?.label ?? tab.label,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (charts.isNotEmpty)
                IconButton(
                  tooltip: tab.chartsOpen ? 'Hide charts' : 'Show charts',
                  icon: const Icon(Icons.insert_chart_outlined, size: 18.0),
                  onPressed: () =>
                      setState(() => tab.chartsOpen = !tab.chartsOpen),
                ),
              IconButton(
                tooltip: tab.showSql ? 'Hide SQL' : 'Show SQL',
                icon: const Icon(Icons.code, size: 18.0),
                onPressed: () => setState(() => tab.showSql = !tab.showSql),
              ),
              FilledButton.icon(
                onPressed: tab.isLoading ? null : _run,
                icon: const Icon(Icons.play_arrow, size: 16.0),
                label: const Text('Run'),
              ),
            ],
          ),
        ),
        if (spec?.description != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12.0, 6.0, 12.0, 0.0),
            child: Text(spec!.description!, style: theme.textTheme.bodySmall),
          ),
        if ((spec?.inputs ?? const []).isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12.0, 8.0, 12.0, 0.0),
            child: Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              children: [
                for (final input in spec!.inputs)
                  SizedBox(
                    width: 220.0,
                    child: TextField(
                      controller: _controllerFor(input),
                      decoration: InputDecoration(
                        labelText: input.prompt,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _run(),
                    ),
                  ),
              ],
            ),
          ),
        if (tab.showSql)
          Container(
            margin: const EdgeInsets.fromLTRB(12.0, 8.0, 12.0, 0.0),
            padding: const EdgeInsets.all(8.0),
            constraints: const BoxConstraints(maxHeight: 180.0),
            decoration: BoxDecoration(
              border: Border.all(color: AppPalette.of(context).border),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                spec?.sql ?? tab.sql,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        if (tab.chartsOpen && charts.isNotEmpty && executor != null)
          SizedBox(
            height: 236.0,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8.0),
              children: [
                for (final chart in charts)
                  Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: SizedBox(
                      width: 420.0,
                      child: MetaChartCard(chart: chart, executor: executor),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 6.0),
        const Divider(height: 1.0),
        Expanded(
          child: GridWithInspector(
            grid: DataGrid(
              key: ValueKey('${tab.id}-${tab.data.hashCode}'),
              data: tab.data ?? const GridData(columns: [], rows: []),
              isLoading: tab.isLoading,
              error: tab.error,
              viewMode: tab.viewMode,
              displayByColumn: _displayByColumn(),
              contextMenuExtras: _menuExtras,
              headerBuilder: _headerBuilder(),
              onRowSelected: (index) {
                if (tab.selectedRowIndex == index) return;
                setState(() => tab.selectedRowIndex = index);
                AppState.instance.notifyChange();
              },
            ),
            inspector: ResultInspectorPanel(
              data: tab.data,
              selectedRowIndex: tab.selectedRowIndex,
              connectionId: tab.connectionId,
            ),
          ),
        ),
      ],
    );
  }
}
