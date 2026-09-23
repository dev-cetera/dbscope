import 'package:flutter/material.dart';

/// A pluggable look-and-feel that wraps a Flutter [ThemeData] with a stable
/// `name` so callers can present a theme switcher without depending on
/// concrete theme classes. The active theme is expected to register an
/// [AppPalette] via [ThemeData.extensions]; widgets read role-based colors
/// from there.
abstract class AppTheme {
  String get name;
  ThemeData get themeData;
}
