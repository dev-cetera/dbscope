import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../json_viewer/json_tab.dart';
import '../query/query_tab.dart';
import '../table/table_tab.dart';
import '../tabs/tab_kind.dart';
import '../tabs/tab_model.dart';
import 'theme_registry.dart';
import 'ui_prefs.dart';

export '../jobs/job_tab.dart' show JobTab;
// Tab kinds live in their feature folders; re-exported here so the
// existing `import '../shell/app_state.dart'` pattern still resolves
// every tab type. Each export's underlying file is the source of truth.
export '../json_viewer/json_tab.dart' show JsonTab;
export '../query/query_tab.dart' show QueryTab;
export '../table/table_tab.dart' show AutoRefreshInterval, TableSortState, TableTab;
export '../tabs/tab_model.dart' show TabModel;

class AppState extends ChangeNotifier {
  AppState._();
  static final instance = AppState._();

  /// Hard cap on open tabs. Beyond this, opening a new tab evicts the
  /// least-recently-activated unpinned tab. Pinned tabs and the active
  /// tab are never evicted. If every tab is pinned, the cap is ignored —
  /// the user explicitly opted them in to staying open.
  static const maxTabs = 10;

  final List<TabModel> tabs = [];
  TabModel? _active;
  var _tabClock = 0;
  var _sidebarOnRight = false;
  var _sidebarVisible = true;
  double _sidebarWidth = 280;
  var _propertyInspectorCollapsed = false;
  double _propertyInspectorWidth = 340;
  double _rowHeight = 32;
  double _sqlEditorHeight = 220;

  /// Persisted theme id. Empty until [loadPersisted] and the
  /// [ThemeRegistry] have both run; resolution is deferred so
  /// pre-registry calls can't pick a stale theme.
  var _themeId = '';

  TabModel? get active => _active;
  bool get sidebarOnRight => _sidebarOnRight;
  bool get sidebarVisible => _sidebarVisible;
  double get sidebarWidth => _sidebarWidth;
  bool get propertyInspectorCollapsed => _propertyInspectorCollapsed;
  double get propertyInspectorWidth => _propertyInspectorWidth;
  double get rowHeight => _rowHeight;
  double get sqlEditorHeight => _sqlEditorHeight;

  /// Currently active theme. Returns the registry fallback if the
  /// persisted id is empty or doesn't resolve — keeps the app
  /// renderable when a theme plugin is removed between sessions.
  ThemePlugin? get themePlugin =>
      ThemeRegistry.instance.lookup(_themeId) ?? ThemeRegistry.instance.fallback;

  String get themeId => themePlugin?.id ?? '';

  /// Loads persisted UI preferences. Safe to call multiple times; only
  /// the first call mutates state. Listeners are not notified — call
  /// before the first frame paints so the saved sizes drive layout.
  Future<void> loadPersisted() async {
    await UiPrefs.instance.init();
    final prefs = UiPrefs.instance;
    final savedSidebarWidth = prefs.sidebarWidth;
    if (savedSidebarWidth != null) {
      _sidebarWidth = savedSidebarWidth.clamp(160.0, 600.0);
    }
    final savedOnRight = prefs.sidebarOnRight;
    if (savedOnRight != null) _sidebarOnRight = savedOnRight;
    final savedVisible = prefs.sidebarVisible;
    if (savedVisible != null) _sidebarVisible = savedVisible;
    final savedInspectorWidth = prefs.inspectorWidth;
    if (savedInspectorWidth != null) {
      _propertyInspectorWidth = savedInspectorWidth.clamp(220.0, 700.0);
    }
    final savedInspectorCollapsed = prefs.inspectorCollapsed;
    if (savedInspectorCollapsed != null) {
      _propertyInspectorCollapsed = savedInspectorCollapsed;
    }
    final savedRowHeight = prefs.rowHeight;
    if (savedRowHeight != null) {
      _rowHeight = savedRowHeight.clamp(20.0, 100.0);
    }
    final savedSqlEditorHeight = prefs.sqlEditorHeight;
    if (savedSqlEditorHeight != null) {
      _sqlEditorHeight = savedSqlEditorHeight.clamp(120.0, 800.0);
    }
    final savedThemeMode = prefs.themeMode;
    if (savedThemeMode != null) _themeId = savedThemeMode;
  }

  var _persistTabsEnabled = false;

  /// Enable tab-list persistence. The host window calls this once at
  /// startup; sub-windows don't, so their ephemeral tab state never
  /// clobbers the host's saved list (SharedPreferences is shared
  /// process-wide).
  void enableTabPersistence() {
    _persistTabsEnabled = true;
  }

  void _persistTabs() {
    final blob = _openTabsBlob();
    if (blob != null) unawaited(UiPrefs.instance.setOpenTabsJson(blob));
  }

  /// Persist the open tabs now and wait for the write. Tab actions
  /// persist as they happen, but in-place edits don't (SQL typed into a
  /// query tab only reaches prefs on the next tab action) — the host's
  /// quit hook calls this so they survive a restart.
  Future<void> flushTabs() async {
    final blob = _openTabsBlob();
    if (blob == null) return;
    try {
      await UiPrefs.instance.setOpenTabsJson(blob);
    } catch (e) {
      debugPrint('Saving open tabs on quit failed: $e');
    }
  }

  String? _openTabsBlob() {
    if (!_persistTabsEnabled) return null;
    final registry = TabKindRegistry.instance;
    final entries = <Map<String, Object?>>[];
    for (final tab in tabs) {
      final kind = registry.lookupForTab(tab);
      final serialized = kind?.serialize?.call(tab);
      if (serialized != null) entries.add(serialized);
    }
    return jsonEncode({
      'version': 1,
      'tabs': entries,
      'activeId': _active?.id,
    });
  }

  /// Restore tabs from prefs. Idempotent: subsequent calls are no-ops if
  /// the tab list is non-empty. Tab kinds without a deserializer (e.g.
  /// JobTab, JsonTab) are transient and skip persistence.
  void restorePersistedTabs() {
    if (tabs.isNotEmpty) return;
    final blob = UiPrefs.instance.openTabsJson;
    if (blob == null || blob.isEmpty) return;
    Map<String, Object?> decoded;
    try {
      final raw = jsonDecode(blob);
      if (raw is! Map<String, Object?>) return;
      decoded = raw;
    } catch (_) {
      return;
    }
    final list = decoded['tabs'];
    if (list is! List) return;
    final registry = TabKindRegistry.instance;
    final restored = <TabModel>[];
    for (final entry in list) {
      if (entry is! Map<String, Object?>) continue;
      final kindId = entry['kind'] as String?;
      if (kindId == null) continue;
      final kind = registry.lookupById(kindId);
      final tab = kind?.deserialize?.call(entry);
      if (tab == null) continue;
      tab.pinned = entry['pinned'] as bool? ?? false;
      restored.add(tab);
      if (restored.length >= maxTabs) break;
    }
    if (restored.isEmpty) return;
    tabs.addAll(restored);
    final activeId = decoded['activeId'] as String?;
    if (activeId != null) {
      for (final tab in restored) {
        if (tab.id == activeId) {
          _active = tab;
          tab.lastActivatedAt = ++_tabClock;
          break;
        }
      }
    }
    _active ??= restored.first;
    _active!.lastActivatedAt = ++_tabClock;
    notifyListeners();
  }

  /// Uniform row height for every grid in the app. Clamped to keep cell
  /// content rendering sane (cell editors and inline FK chips assume a
  /// minimum height; very tall rows just waste pixels).
  void setRowHeight(double height) {
    final clamped = height.clamp(20.0, 100.0);
    if (clamped == _rowHeight) return;
    _rowHeight = clamped;
    UiPrefs.instance.setRowHeight(_rowHeight);
    notifyListeners();
  }

  /// Picks a theme by its registered id. Unknown ids are ignored
  /// rather than silently falling back, so a plugin author can spot a
  /// typo right away.
  void setThemeId(String id) {
    if (id == _themeId) return;
    if (ThemeRegistry.instance.lookup(id) == null) return;
    _themeId = id;
    UiPrefs.instance.setThemeMode(id);
    notifyListeners();
  }

  /// Cycles through the registered themes in registration order.
  void cycleTheme() {
    final all = ThemeRegistry.instance.all;
    if (all.isEmpty) return;
    final current = themePlugin;
    final index = current == null ? -1 : all.indexWhere((theme) => theme.id == current.id);
    final next = all[(index + 1) % all.length];
    setThemeId(next.id);
  }

  void toggleSidebar() {
    _sidebarOnRight = !_sidebarOnRight;
    UiPrefs.instance.setSidebarOnRight(onRight: _sidebarOnRight);
    notifyListeners();
  }

  void toggleSidebarVisible() {
    _sidebarVisible = !_sidebarVisible;
    UiPrefs.instance.setSidebarVisible(visible: _sidebarVisible);
    notifyListeners();
  }

  void setSidebarWidth(double width) {
    _sidebarWidth = width.clamp(160.0, 600.0);
    UiPrefs.instance.setSidebarWidth(_sidebarWidth);
    notifyListeners();
  }

  void togglePropertyInspector() {
    _propertyInspectorCollapsed = !_propertyInspectorCollapsed;
    UiPrefs.instance.setInspectorCollapsed(
      collapsed: _propertyInspectorCollapsed,
    );
    notifyListeners();
  }

  void setPropertyInspectorWidth(double width) {
    _propertyInspectorWidth = width.clamp(220.0, 700.0);
    UiPrefs.instance.setInspectorWidth(_propertyInspectorWidth);
    notifyListeners();
  }

  void setSqlEditorHeight(double height) {
    final clamped = height.clamp(120.0, 800.0);
    if (clamped == _sqlEditorHeight) return;
    _sqlEditorHeight = clamped;
    UiPrefs.instance.setSqlEditorHeight(_sqlEditorHeight);
    notifyListeners();
  }

  void openTab(TabModel tab) {
    tabs.add(tab);
    tab.lastActivatedAt = ++_tabClock;
    _active = tab;
    _evictIfOverCap();
    _persistTabs();
    notifyListeners();
  }

  /// Evict the least-recently-activated unpinned tab until at or below
  /// [maxTabs]. The active tab is implicitly safe — it was just activated
  /// in [openTab] / [selectTab] and has the largest `lastActivatedAt`.
  void _evictIfOverCap() {
    while (tabs.length > maxTabs) {
      final candidates = tabs.where((tab) => !tab.pinned && tab.id != _active?.id).toList();
      if (candidates.isEmpty) return;
      candidates.sort((a, b) => a.lastActivatedAt.compareTo(b.lastActivatedAt));
      final victim = candidates.first;
      victim.cancelToken?.cancel();
      tabs.remove(victim);
    }
  }

  void openOrFocusTable({
    required String connectionId,
    required String schema,
    required String table,
    required int estimatedRows,
  }) {
    final existing = tabs.firstWhere(
      (tab) =>
          tab is TableTab &&
          tab.metaFilter == null &&
          tab.connectionId == connectionId &&
          tab.schema == schema &&
          tab.table == table,
      orElse: () => _Sentinel.instance,
    );
    if (existing is! _Sentinel) {
      _active = existing;
      existing.lastActivatedAt = ++_tabClock;
      _persistTabs();
      notifyListeners();
      return;
    }
    openTab(
      TableTab(
        connectionId: connectionId,
        schema: schema,
        table: table,
        estimatedRows: estimatedRows,
      ),
    );
  }

  void newQueryTab(
    String connectionId, {
    String? initialSql,
    String? title,
    bool autoRun = false,
  }) {
    openTab(
      QueryTab(
        connectionId: connectionId,
        sql: initialSql ?? '',
        titleOverride: title,
        autoRun: autoRun,
      ),
    );
  }

  /// Open a new Query tab with the AI prompt strip pre-expanded and a
  /// focus hint pre-filled. Replaces the old `newAiQueryTab` entry point
  /// — the AI prompt now lives inside the unified Query tab.
  void newAiQueryTab(
    String connectionId, {
    String? initialPrompt,
    String? title,
    String? focusSchema,
    String? focusTable,
    String? generatedSql,
    String? savedName,
  }) {
    openTab(
      QueryTab(
        connectionId: connectionId,
        prompt: initialPrompt ?? '',
        sql: generatedSql ?? '',
        titleOverride: title,
        savedName: savedName,
        focusSchema: focusSchema,
        focusTable: focusTable,
      ),
    );
  }

  void openJsonTab({
    required String connectionId,
    required String columnName,
    required String content,
  }) {
    openTab(
      JsonTab(
        connectionId: connectionId,
        columnName: columnName,
        content: content,
      ),
    );
  }

  void closeTab(String id) {
    final index = tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    final removed = tabs.removeAt(index);
    removed.cancelToken?.cancel();
    if (_active?.id == id) {
      if (tabs.isEmpty) {
        _active = null;
      } else {
        _active = tabs[index == tabs.length ? index - 1 : index];
      }
    }
    _persistTabs();
    notifyListeners();
  }

  /// Reorder a tab. `newIndex` is interpreted in the post-removal frame,
  /// matching `ReorderableListView.onReorder` semantics after the caller's
  /// `newIndex -= 1` adjustment for forward moves.
  void moveTab(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tabs.length) return;
    var target = newIndex;
    if (target < 0) target = 0;
    if (target > tabs.length - 1) target = tabs.length - 1;
    if (oldIndex == target) return;
    final tab = tabs.removeAt(oldIndex);
    tabs.insert(target, tab);
    _persistTabs();
    notifyListeners();
  }

  void selectTab(String id) {
    final found = tabs.firstWhere(
      (tab) => tab.id == id,
      orElse: () => _Sentinel.instance,
    );
    if (found is _Sentinel) return;
    _active = found;
    found.lastActivatedAt = ++_tabClock;
    _persistTabs();
    notifyListeners();
  }

  void togglePin(String id) {
    final found = tabs.firstWhere(
      (tab) => tab.id == id,
      orElse: () => _Sentinel.instance,
    );
    if (found is _Sentinel) return;
    found.pinned = !found.pinned;
    _persistTabs();
    notifyListeners();
  }

  /// Close every tab except [keepId] and any pinned tab.
  void closeOtherTabs(String keepId) {
    final removed = tabs.where((tab) => tab.id != keepId && !tab.pinned).toList();
    for (final tab in removed) {
      tab.cancelToken?.cancel();
    }
    tabs.removeWhere((tab) => tab.id != keepId && !tab.pinned);
    if (_active != null && !tabs.contains(_active)) {
      _active = tabs.isEmpty ? null : tabs.first;
    }
    _persistTabs();
    notifyListeners();
  }

  /// Close every unpinned tab to the right of [anchorId].
  void closeTabsToRight(String anchorId) {
    final anchorIndex = tabs.indexWhere((tab) => tab.id == anchorId);
    if (anchorIndex < 0) return;
    final toRemove = <TabModel>[];
    for (var i = anchorIndex + 1; i < tabs.length; i++) {
      if (!tabs[i].pinned) toRemove.add(tabs[i]);
    }
    for (final tab in toRemove) {
      tab.cancelToken?.cancel();
    }
    tabs.removeWhere(toRemove.contains);
    if (_active != null && !tabs.contains(_active)) {
      _active = tabs[anchorIndex];
    }
    _persistTabs();
    notifyListeners();
  }

  /// Close every unpinned tab to the left of [anchorId].
  void closeTabsToLeft(String anchorId) {
    final anchorIndex = tabs.indexWhere((tab) => tab.id == anchorId);
    if (anchorIndex <= 0) return;
    final toRemove = <TabModel>[];
    for (var i = 0; i < anchorIndex; i++) {
      if (!tabs[i].pinned) toRemove.add(tabs[i]);
    }
    for (final tab in toRemove) {
      tab.cancelToken?.cancel();
    }
    tabs.removeWhere(toRemove.contains);
    if (_active != null && !tabs.contains(_active)) {
      _active = tabs.first;
    }
    _persistTabs();
    notifyListeners();
  }

  void closeTabsForConnection(String connectionId) {
    final removed = tabs.where((tab) => tab.connectionId == connectionId).toList();
    for (final tab in removed) {
      tab.cancelToken?.cancel();
    }
    tabs.removeWhere((tab) => tab.connectionId == connectionId);
    if (_active != null && _active!.connectionId == connectionId) {
      _active = tabs.isEmpty ? null : tabs.first;
    }
    _persistTabs();
    notifyListeners();
  }

  Iterable<TabModel> runningTabs() {
    final registry = TabKindRegistry.instance;
    return tabs.where((tab) {
      final isRunning = registry.lookupForTab(tab)?.isRunning;
      return isRunning != null && isRunning(tab);
    });
  }

  void cancelAll() {
    for (final tab in runningTabs()) {
      tab.cancelToken?.cancel();
    }
    notifyListeners();
  }

  void notifyChange() => notifyListeners();
}

class _Sentinel extends TabModel {
  _Sentinel() : super(id: '__sentinel__', connectionId: '');
  static final instance = _Sentinel();
  @override
  String get title => '';
}
