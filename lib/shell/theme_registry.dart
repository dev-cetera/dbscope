import 'package:flutter/material.dart';

/// One look-and-feel that the user can pick from the View → Theme menu.
/// A theme owns its [ThemeData] and (optionally) full-app overlays that
/// appear when that theme is active — e.g. the Doom theme's mugshot.
///
/// Themes are pluggable: built-ins ship in their own packages
/// (`packages/dbscope_theme_*` and `packages/dbscope_doom_plugin`) and
/// register themselves from `main.dart`. Removing the package removes
/// the theme entirely — no references survive in core.
class ThemePlugin {
  /// Stable id persisted as the user's chosen theme. Never rename; old
  /// stored preferences would fail to resolve.
  final String id;

  /// Human-readable label for the picker.
  final String label;

  /// Builds the [ThemeData] for this look. Called per frame when the
  /// theme is active, so keep it cheap or memoise inside the builder.
  final ThemeData Function() build;

  /// Optional full-app overlay widgets shown in the root `Stack` when
  /// this theme is active. Each is recreated on theme change.
  final List<WidgetBuilder> overlays;

  const ThemePlugin({
    required this.id,
    required this.label,
    required this.build,
    this.overlays = const [],
  });
}

/// Process-wide registry of theme plugins. `main.dart` calls
/// `register` once per theme; the View menu and theme switcher read
/// `all` to populate.
class ThemeRegistry {
  ThemeRegistry._();
  static final ThemeRegistry instance = ThemeRegistry._();

  final List<ThemePlugin> _ordered = [];
  final Map<String, ThemePlugin> _byId = {};

  void register(ThemePlugin theme) {
    if (_byId.containsKey(theme.id)) {
      _ordered.removeWhere((t) => t.id == theme.id);
    }
    _byId[theme.id] = theme;
    _ordered.add(theme);
  }

  ThemePlugin? lookup(String id) => _byId[id];

  /// First-registered theme used as a fallback when the persisted id
  /// no longer resolves (e.g. user removed the plugin between runs).
  ThemePlugin? get fallback => _ordered.isEmpty ? null : _ordered.first;

  List<ThemePlugin> get all => List.unmodifiable(_ordered);
}
