import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists per-machine preferences across launches: sidebar width and
/// side, inspector width and collapsed state, theme, SQL editor height,
/// row height, the last connection, the open tabs, and the shell env
/// file path.
///
/// Each setter is fire-and-forget — callers don't await. SharedPreferences
/// is process-global, so a subwindow's read still sees the host's write
/// after a short delay; not a problem in practice since prefs only
/// affect first-frame layout on next launch.
class UiPrefs {
  UiPrefs._();
  static final UiPrefs instance = UiPrefs._();

  static const _kSidebarWidth = 'ui.sidebarWidth';
  static const _kSidebarOnRight = 'ui.sidebarOnRight';
  static const _kSidebarVisible = 'ui.sidebarVisible';
  static const _kInspectorWidth = 'ui.inspectorWidth';
  static const _kInspectorCollapsed = 'ui.inspectorCollapsed';
  static const _kThemeMode = 'ui.themeMode';
  static const _kSqlEditorHeight = 'ui.sqlEditorHeight';
  static const _kRowHeight = 'ui.rowHeight';
  static const _kLastConnectionId = 'ui.lastConnectionId';
  static const _kOpenTabs = 'ui.openTabs';
  static const _kEnvFilePath = 'env.filePath';

  SharedPreferences? _prefs;

  Future<void> init() async {
    if (_prefs != null) return;
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e, st) {
      // SharedPreferences fails when the platform plugin isn't bound to
      // this engine — happens in desktop_multi_window subwindows (each
      // subwindow has its own engine and only registers the plugins its
      // runner explicitly requests) and in restricted web contexts
      // (private browsing, third-party-cookie blocks, etc.). Every
      // getter/setter on this class is null-tolerant, so leaving _prefs
      // null degrades to in-memory defaults instead of crashing.
      debugPrint(
        'UiPrefs.init: SharedPreferences unavailable ($e). '
        'Continuing with defaults.\n$st',
      );
    }
  }

  double? get sidebarWidth => _prefs?.getDouble(_kSidebarWidth);
  bool? get sidebarOnRight => _prefs?.getBool(_kSidebarOnRight);
  bool? get sidebarVisible => _prefs?.getBool(_kSidebarVisible);
  double? get inspectorWidth => _prefs?.getDouble(_kInspectorWidth);
  bool? get inspectorCollapsed => _prefs?.getBool(_kInspectorCollapsed);
  String? get themeMode => _prefs?.getString(_kThemeMode);
  double? get sqlEditorHeight => _prefs?.getDouble(_kSqlEditorHeight);
  double? get rowHeight => _prefs?.getDouble(_kRowHeight);
  String? get lastConnectionId => _prefs?.getString(_kLastConnectionId);
  String? get openTabsJson => _prefs?.getString(_kOpenTabs);

  /// Shell env file to read variables from. Null means "use
  /// `ShellEnv.defaultPath`" — the user has not overridden it.
  String? get envFilePath => _prefs?.getString(_kEnvFilePath);

  void setSidebarWidth(double v) => _prefs?.setDouble(_kSidebarWidth, v);
  void setSidebarOnRight(bool v) => _prefs?.setBool(_kSidebarOnRight, v);
  void setSidebarVisible(bool v) => _prefs?.setBool(_kSidebarVisible, v);
  void setInspectorWidth(double v) => _prefs?.setDouble(_kInspectorWidth, v);
  void setInspectorCollapsed(bool v) =>
      _prefs?.setBool(_kInspectorCollapsed, v);
  void setThemeMode(String v) => _prefs?.setString(_kThemeMode, v);
  void setSqlEditorHeight(double v) => _prefs?.setDouble(_kSqlEditorHeight, v);
  void setRowHeight(double v) => _prefs?.setDouble(_kRowHeight, v);
  void setLastConnectionId(String? v) => _setOrRemove(_kLastConnectionId, v);

  void setOpenTabsJson(String v) => _prefs?.setString(_kOpenTabs, v);

  void setEnvFilePath(String? v) => _setOrRemove(_kEnvFilePath, v);

  /// Stores [v] trimmed, or drops the key when there is nothing to store.
  /// Removing rather than writing `''` is what lets a reader tell "never set"
  /// from "set to empty" — the whole point of the nullable getters.
  void _setOrRemove(String key, String? v) {
    final trimmed = v?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      _prefs?.remove(key);
    } else {
      _prefs?.setString(key, trimmed);
    }
  }
}
