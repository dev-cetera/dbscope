import 'package:flutter/material.dart';

/// Colors + dimensions the grid needs to paint itself. Defaults are
/// derived from the ambient [ThemeData] so the grid looks reasonable
/// out of the box; pass a custom [GridStyle] to override.
@immutable
class GridStyle {
  /// Cell background when not selected.
  final Color cellBackground;

  /// Cell background when part of the selection range (but not the
  /// focused cell).
  final Color selectionBackground;

  /// Cell background for the focused cell (the cursor).
  final Color focusBackground;

  /// Cell border (between cells).
  final Color cellBorder;

  /// Strong border under the header row.
  final Color headerBorderStrong;

  /// Accent color for the focused-cell outline, sort arrow, drop
  /// indicator while reordering columns.
  final Color accent;

  /// Soft accent — gutter highlight when a row is selected.
  final Color accentSoft;

  /// Header + gutter background.
  final Color headerBackground;

  /// Primary text color in cells and headers.
  final Color textColor;

  /// Muted text color (column type subtitles, gutter numbers).
  final Color mutedTextColor;

  /// Text style for cell body content (rendered by the default
  /// renderer; custom renderers may pick their own).
  final TextStyle cellTextStyle;

  /// Text style for header column names.
  final TextStyle headerTitleStyle;

  /// Text style for header subtitles (type label) + gutter numbers.
  final TextStyle headerSubtitleStyle;

  const GridStyle({
    required this.cellBackground,
    required this.selectionBackground,
    required this.focusBackground,
    required this.cellBorder,
    required this.headerBorderStrong,
    required this.accent,
    required this.accentSoft,
    required this.headerBackground,
    required this.textColor,
    required this.mutedTextColor,
    required this.cellTextStyle,
    required this.headerTitleStyle,
    required this.headerSubtitleStyle,
  });

  /// Sensible defaults derived from a material [ThemeData].
  factory GridStyle.fromTheme(ThemeData theme) {
    final cs = theme.colorScheme;
    final textColor = cs.onSurface;
    final muted = cs.onSurfaceVariant;
    return GridStyle(
      cellBackground: cs.surface,
      selectionBackground: cs.primary.withValues(alpha: 0.10),
      focusBackground: cs.primary.withValues(alpha: 0.18),
      cellBorder: cs.outlineVariant,
      headerBorderStrong: cs.outline,
      accent: cs.primary,
      accentSoft: cs.primary.withValues(alpha: 0.15),
      headerBackground: cs.surfaceContainerHigh,
      textColor: textColor,
      mutedTextColor: muted,
      cellTextStyle: TextStyle(color: textColor, fontSize: 12),
      headerTitleStyle: TextStyle(
        color: textColor,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
      headerSubtitleStyle: TextStyle(color: muted, fontSize: 11),
    );
  }

  GridStyle copyWith({
    Color? cellBackground,
    Color? selectionBackground,
    Color? focusBackground,
    Color? cellBorder,
    Color? headerBorderStrong,
    Color? accent,
    Color? accentSoft,
    Color? headerBackground,
    Color? textColor,
    Color? mutedTextColor,
    TextStyle? cellTextStyle,
    TextStyle? headerTitleStyle,
    TextStyle? headerSubtitleStyle,
  }) =>
      GridStyle(
        cellBackground: cellBackground ?? this.cellBackground,
        selectionBackground: selectionBackground ?? this.selectionBackground,
        focusBackground: focusBackground ?? this.focusBackground,
        cellBorder: cellBorder ?? this.cellBorder,
        headerBorderStrong: headerBorderStrong ?? this.headerBorderStrong,
        accent: accent ?? this.accent,
        accentSoft: accentSoft ?? this.accentSoft,
        headerBackground: headerBackground ?? this.headerBackground,
        textColor: textColor ?? this.textColor,
        mutedTextColor: mutedTextColor ?? this.mutedTextColor,
        cellTextStyle: cellTextStyle ?? this.cellTextStyle,
        headerTitleStyle: headerTitleStyle ?? this.headerTitleStyle,
        headerSubtitleStyle: headerSubtitleStyle ?? this.headerSubtitleStyle,
      );
}

/// Resolves [GridStyle] from a context: explicit > theme extension >
/// default-from-theme. Use this at the top of any grid-internal widget
/// that needs styling.
GridStyle resolveGridStyle(BuildContext context, [GridStyle? explicit]) {
  if (explicit != null) return explicit;
  final theme = Theme.of(context);
  final ext = theme.extension<GridStyleExtension>();
  if (ext != null) return ext.style;
  return GridStyle.fromTheme(theme);
}

/// Optional [ThemeExtension] wrapper so apps can plug a [GridStyle]
/// into their [ThemeData.extensions] without touching every grid
/// callsite.
class GridStyleExtension extends ThemeExtension<GridStyleExtension> {
  final GridStyle style;
  const GridStyleExtension(this.style);

  @override
  GridStyleExtension copyWith({GridStyle? style}) =>
      GridStyleExtension(style ?? this.style);

  @override
  GridStyleExtension lerp(ThemeExtension<GridStyleExtension>? other, double t) {
    // Grid colors are discrete — snap rather than blending. If your
    // theme animates, supply a custom extension with a real lerp.
    if (other is! GridStyleExtension) return this;
    return t < 0.5 ? this : other;
  }
}
