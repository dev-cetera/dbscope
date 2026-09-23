import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../ai/sql_assistant.dart';
import '../catalog/dbml_cache.dart';
import '../connection/registry.dart';
import '../db/executor.dart';
import '../grid/data_grid.dart';
import '../grid/export.dart';
import '../inspector/grid_with_inspector.dart';
import '../inspector/result_inspector_panel.dart';
import '../query/cancel_token.dart';
import '../query/history_store.dart';
import '../query/runner.dart';
import '../query/sql_editor.dart';
import '../shell/app_state.dart';
import '../util/pg_errors.dart';

enum _ExportFormat { sql, csv, json, sqlite }

class QueryTabView extends StatefulWidget {
  final QueryTab tab;
  const QueryTabView({super.key, required this.tab});

  @override
  State<QueryTabView> createState() => _QueryTabViewState();
}

class _QueryTabViewState extends State<QueryTabView> {
  List<HistoryEntry> _history = [];
  List<SavedQuery> _saved = [];
  late final TextEditingController _promptCtrl;

  static const double _historyRailWidth = 220;

  @override
  void initState() {
    super.initState();
    _promptCtrl = TextEditingController(text: widget.tab.prompt);
    DbmlCache.instance.addListener(_onCacheChanged);
    _loadHistoryAndSaved();
    if (widget.tab.autoRun &&
        widget.tab.data == null &&
        !widget.tab.isLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.tab.autoRun = false;
        _run();
      });
    }
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    DbmlCache.instance.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHistoryAndSaved() async {
    final h = await HistoryStore.instance.loadHistory(widget.tab.connectionId);
    final s = await HistoryStore.instance.loadSaved(widget.tab.connectionId);
    if (!mounted) return;
    setState(() {
      _history = h;
      _saved = s;
    });
  }

  DbExecutor? _conn() =>
      ConnectionRegistry.instance.connectionFor(widget.tab.connectionId);

  Future<void> _run() async {
    final conn = _conn();
    if (conn == null) {
      setState(() => widget.tab.error = 'No connection.');
      AppState.instance.notifyChange();
      return;
    }
    if (widget.tab.sql.trim().isEmpty) return;
    final token = CancelToken();
    setState(() {
      widget.tab.isLoading = true;
      widget.tab.error = null;
      widget.tab.cancelToken = token;
    });
    AppState.instance.notifyChange();
    try {
      final runner = QueryRunner(conn);
      final result = await runner.runSql(widget.tab.sql, cancelToken: token);
      if (!mounted) return;
      setState(() {
        widget.tab.data = result.data;
        widget.tab.elapsed = result.elapsed;
        widget.tab.truncated = result.truncated;
        widget.tab.isLoading = false;
        widget.tab.cancelToken = null;
      });
      await HistoryStore.instance.appendHistory(
        widget.tab.connectionId,
        widget.tab.sql,
      );
      await _loadHistoryAndSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        widget.tab.error = classify(e).message;
        widget.tab.isLoading = false;
        widget.tab.cancelToken = null;
      });
    } finally {
      AppState.instance.notifyChange();
    }
  }

  Future<void> _askAi() async {
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty) return;
    final conn = _conn();
    if (conn == null) {
      showToast(context, 'Connect first.');
      return;
    }
    setState(() {
      widget.tab.prompt = prompt;
      widget.tab.isAsking = true;
      widget.tab.error = null;
    });
    AppState.instance.notifyChange();
    try {
      final assistant = SqlAssistant(conn, profileId: widget.tab.connectionId);
      final sql = await assistant.askSql(
        prompt,
        focusSchema: widget.tab.focusSchema,
        focusTable: widget.tab.focusTable,
      );
      if (!mounted) return;
      setState(() {
        widget.tab.isAsking = false;
        widget.tab.sql = sql;
      });
      AppState.instance.notifyChange();
      await _run();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        widget.tab.isAsking = false;
        widget.tab.error = 'AI: $e';
      });
      AppState.instance.notifyChange();
    }
  }

  Future<void> _save() async {
    final controller = TextEditingController(text: widget.tab.savedName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Save query'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final list = List<SavedQuery>.from(_saved);
    final existingIdx = list.indexWhere((s) => s.name == name);
    final id = existingIdx >= 0
        ? list[existingIdx].id
        : DateTime.now().millisecondsSinceEpoch.toString();
    final entry = SavedQuery(id: id, name: name, sql: widget.tab.sql);
    if (existingIdx >= 0) {
      list[existingIdx] = entry;
    } else {
      list.add(entry);
    }
    await HistoryStore.instance.saveSaved(widget.tab.connectionId, list);
    setState(() {
      _saved = list;
      widget.tab.savedName = name;
    });
    AppState.instance.notifyChange();
  }

  Future<void> _deleteSaved(SavedQuery q) async {
    final list = List<SavedQuery>.from(_saved)
      ..removeWhere((s) => s.id == q.id);
    await HistoryStore.instance.saveSaved(widget.tab.connectionId, list);
    setState(() => _saved = list);
  }

  Future<void> _export(_ExportFormat format) async {
    try {
      final path = switch (format) {
        _ExportFormat.sql => await ResultExporter.exportSqlText(widget.tab.sql),
        _ExportFormat.csv => await ResultExporter.exportCsv(widget.tab.data!),
        _ExportFormat.json => await ResultExporter.exportJson(widget.tab.data!),
        _ExportFormat.sqlite => await ResultExporter.exportSqlite(
          widget.tab.data!,
        ),
      };
      if (!mounted) return;
      if (path != null) showToast(context, 'Saved to $path');
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'Export failed: $e');
    }
  }

  void _toggleHistoryRail() {
    setState(() {
      widget.tab.historyRailOpen = !widget.tab.historyRailOpen;
    });
    AppState.instance.notifyChange();
  }

  void _loadHistorySql(String sql) {
    setState(() => widget.tab.sql = sql);
    AppState.instance.notifyChange();
  }

  void _loadSavedQuery(SavedQuery q) {
    setState(() {
      widget.tab.sql = q.sql;
      widget.tab.savedName = q.name;
    });
    AppState.instance.notifyChange();
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final hasResultData = tab.data != null;
    return Column(
      children: [
        PanelHeader(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          titleIcon: Icons.code,
          title: 'Query',
          subtitle: tab.focusTable != null
              ? 'Focus: ${tab.focusSchema}.${tab.focusTable}'
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tab.historyRailOpen ? 'Hide history' : 'Show history',
                icon: Icon(
                  tab.historyRailOpen ? Icons.history : Icons.history_outlined,
                  size: 18,
                ),
                onPressed: _toggleHistoryRail,
              ),
              IconButton(
                tooltip: 'Save query',
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                onPressed: tab.sql.trim().isEmpty ? null : _save,
              ),
              IconButton(
                tooltip: 'Download .sql',
                icon: const Icon(Icons.file_download_outlined, size: 18),
                onPressed: tab.sql.trim().isEmpty
                    ? null
                    : () => _export(_ExportFormat.sql),
              ),
              if (hasResultData) ...[
                TextButton.icon(
                  icon: const Icon(Icons.table_chart_outlined, size: 14),
                  label: const Text('CSV'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _export(_ExportFormat.csv),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.data_object, size: 14),
                  label: const Text('JSON'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _export(_ExportFormat.json),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.storage, size: 14),
                  label: const Text('.db'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _export(_ExportFormat.sqlite),
                ),
              ],
              FilledButton.icon(
                onPressed: tab.isLoading ? null : _run,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Run'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              IconButton(
                tooltip: AppState.instance.propertyInspectorCollapsed
                    ? 'Show row inspector'
                    : 'Hide row inspector',
                icon: Icon(
                  AppState.instance.propertyInspectorCollapsed
                      ? Icons.view_sidebar_outlined
                      : Icons.view_sidebar,
                  size: 18,
                ),
                onPressed: AppState.instance.togglePropertyInspector,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        _AiPromptStrip(
          tab: tab,
          controller: _promptCtrl,
          onAsk: _askAi,
          onClearFocus: () {
            setState(() {
              tab.focusSchema = null;
              tab.focusTable = null;
            });
            AppState.instance.notifyChange();
          },
        ),
        // Editor + grid live in a flat Column when the history rail is
        // closed (matches the original layout depth — flutter_code_editor
        // races during async analyzeCode if its RenderBox isn't laid out
        // by the time the first notification fires). When the rail is
        // open, wrap in a Row.
        if (tab.historyRailOpen)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: _historyRailWidth,
                  child: _HistoryRail(
                    history: _history,
                    saved: _saved,
                    activeSavedName: tab.savedName,
                    onSelectHistory: _loadHistorySql,
                    onSelectSaved: _loadSavedQuery,
                    onDeleteSaved: _deleteSaved,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: _buildEditorAndGrid(tab)),
              ],
            ),
          )
        else
          Expanded(child: _buildEditorAndGrid(tab)),
      ],
    );
  }

  Widget _buildEditorAndGrid(QueryTab tab) {
    return Column(
      children: [
        VResizable(
          height: AppState.instance.sqlEditorHeight,
          minHeight: 120,
          maxHeight: 800,
          onResized: AppState.instance.setSqlEditorHeight,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SqlEditor(
              initialText: widget.tab.sql,
              onChanged: (text) {
                widget.tab.sql = text;
              },
              onRun: _run,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: GridWithInspector(
            grid: DataGrid(
              key: ValueKey(tab.id),
              data: tab.data ?? const GridData(columns: [], rows: []),
              isLoading: tab.isLoading,
              error: tab.error,
              viewMode: tab.viewMode,
              onRowSelected: (idx) {
                if (widget.tab.selectedRowIndex == idx) return;
                setState(() => widget.tab.selectedRowIndex = idx);
                AppState.instance.notifyChange();
              },
            ),
            inspector: ResultInspectorPanel(
              schema: tab.focusSchema,
              table: tab.focusTable,
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

class _AiPromptStrip extends StatelessWidget {
  final QueryTab tab;
  final TextEditingController controller;
  final Future<void> Function() onAsk;
  final VoidCallback onClearFocus;
  const _AiPromptStrip({
    required this.tab,
    required this.controller,
    required this.onAsk,
    required this.onClearFocus,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final status = DbmlCache.instance.statusFor(tab.connectionId);
    final ready = status == DbmlStatus.ready;
    final pending = status == DbmlStatus.pending;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: palette.surfaceRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;
                    if (event.logicalKey != LogicalKeyboardKey.enter &&
                        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
                      return KeyEventResult.ignored;
                    }
                    if (HardwareKeyboard.instance.isShiftPressed) {
                      return KeyEventResult.ignored;
                    }
                    if (!ready || tab.isAsking) return KeyEventResult.handled;
                    onAsk();
                    return KeyEventResult.handled;
                  },
                  child: TextField(
                    controller: controller,
                    enabled: !tab.isAsking,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(
                      fontFamily: palette.uiFontFamily,
                      fontSize: palette.bodyFontSize,
                    ),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.auto_awesome, size: 16),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      hintText: ready
                          ? 'Ask in plain English · Enter to generate'
                          : pending
                          ? 'Indexing schema… please wait'
                          : 'Connect to a database to start',
                      hintStyle: TextStyle(color: palette.mutedText),
                    ),
                    onChanged: (v) {
                      tab.prompt = v;
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: (!ready || tab.isAsking) ? null : onAsk,
                icon: tab.isAsking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bolt, size: 16),
                label: const Text('Generate'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (tab.focusTable != null || pending) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (tab.focusTable != null) ...[
                  Icon(
                    Icons.center_focus_strong,
                    size: 13,
                    color: palette.mutedText,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${tab.focusSchema}.${tab.focusTable}',
                    style: TextStyle(
                      fontSize: palette.smallFontSize,
                      color: palette.mutedText,
                      fontFamily: palette.uiFontFamily,
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: onClearFocus,
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: palette.mutedText,
                    ),
                  ),
                ],
                const Spacer(),
                if (pending)
                  Row(
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Indexing schema…',
                        style: TextStyle(
                          fontSize: palette.smallFontSize,
                          color: palette.mutedText,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HistoryRail extends StatefulWidget {
  final List<HistoryEntry> history;
  final List<SavedQuery> saved;
  final String? activeSavedName;
  final ValueChanged<String> onSelectHistory;
  final ValueChanged<SavedQuery> onSelectSaved;
  final ValueChanged<SavedQuery> onDeleteSaved;
  const _HistoryRail({
    required this.history,
    required this.saved,
    required this.activeSavedName,
    required this.onSelectHistory,
    required this.onSelectSaved,
    required this.onDeleteSaved,
  });

  @override
  State<_HistoryRail> createState() => _HistoryRailState();
}

class _HistoryRailState extends State<_HistoryRail> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final filter = _filter.toLowerCase();
    final saved = filter.isEmpty
        ? widget.saved
        : widget.saved
              .where(
                (q) =>
                    q.name.toLowerCase().contains(filter) ||
                    q.sql.toLowerCase().contains(filter),
              )
              .toList();
    final history = filter.isEmpty
        ? widget.history
        : widget.history
              .where((e) => e.sql.toLowerCase().contains(filter))
              .toList();
    return Container(
      color: palette.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 14),
                hintText: 'Filter…',
                hintStyle: TextStyle(
                  fontSize: palette.smallFontSize,
                  color: palette.mutedText,
                ),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 8,
                ),
              ),
              style: TextStyle(
                fontSize: palette.smallFontSize,
                fontFamily: palette.uiFontFamily,
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (saved.isNotEmpty)
                  _RailSection(
                    label: 'Saved (${saved.length})',
                    icon: Icons.bookmark_outline,
                  ),
                for (final q in saved)
                  _SavedRow(
                    q: q,
                    active: q.name == widget.activeSavedName,
                    onTap: () => widget.onSelectSaved(q),
                    onDelete: () => widget.onDeleteSaved(q),
                  ),
                if (history.isNotEmpty)
                  _RailSection(
                    label: 'Recent (${history.length})',
                    icon: Icons.history,
                  ),
                for (final e in history.take(100))
                  _HistoryRow(
                    sql: e.sql,
                    onTap: () => widget.onSelectHistory(e.sql),
                  ),
                if (saved.isEmpty && history.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No queries yet. Saved queries and recent runs will show up here.',
                      style: TextStyle(
                        fontSize: palette.smallFontSize,
                        color: palette.mutedText,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailSection extends StatelessWidget {
  final String label;
  final IconData icon;
  const _RailSection({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          Icon(icon, size: 12, color: palette.mutedText),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: palette.smallFontSize,
              fontWeight: FontWeight.w600,
              color: palette.mutedText,
              fontFamily: palette.uiFontFamily,
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedRow extends StatelessWidget {
  final SavedQuery q;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _SavedRow({
    required this.q,
    required this.active,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: active ? palette.surfaceRaised : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.bookmark, size: 12, color: palette.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                q.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: palette.bodyFontSize,
                  fontFamily: palette.uiFontFamily,
                ),
              ),
            ),
            InkWell(
              onTap: onDelete,
              child: Icon(Icons.close, size: 12, color: palette.mutedText),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final String sql;
  final VoidCallback onTap;
  const _HistoryRow({required this.sql, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final summary = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          summary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: palette.monoFontFamily,
            fontSize: palette.smallFontSize,
            color: palette.text,
          ),
        ),
      ),
    );
  }
}
