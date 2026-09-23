import 'package:flutter/material.dart';

import 'package:widgets/widgets.dart';

/// Portal / Aperture Science palette values. Cool clinical whites, signature
/// portal-orange accent, portal-blue selection highlight. Constants live
/// here; widgets read role-based colors via [AppPalette.of].
class _PortalColors {
  // Aperture lab surfaces — clean, cool, sterile.
  static const labWhite = Color(0xFFFFFFFF); // primary panel
  static const labOffWhite = Color(0xFFF7F7F5); // raised surface
  static const labPanel = Color(0xFFECECEA); // recessed surface / sidebar
  static const labDisabled = Color(0xFFF0F0EE);

  // Borders — cool grays.
  static const seam = Color(0xFFC8C8C8);
  static const seamStrong = Color(0xFF5A5A5A);

  // Text — never pure black, keeps the clinical feel.
  static const text = Color(0xFF1A1A1A);
  static const mutedText = Color(0xFF6E6E6E);

  // Signature accent — the orange portal.
  static const portalOrange = Color(0xFFFF6F00);
  static const portalOrangeSoft = Color(0xFFFFE4CC);

  // Secondary accent — the blue portal (used for hover/selection).
  static const portalBlue = Color(0xFF1F8AC0);
  static const portalBlueSoft = Color(0xFFE6F2FA);
  static const portalBlueSelected = Color(0xFFBFE2F5);

  // Editing tint — pale orange, "you are touching live state".
  static const editingTint = Color(0xFFFFE9CC);

  // Data-type cell colors — tuned for legibility on white.
  static const burntOrange = Color(0xFFB85C00);
  static const deepBlue = Color(0xFF1A6FB4);
  static const apertureGreen = Color(0xFF0E7C66);
  static const purple = Color(0xFF6E2C8B);
  static const teal = Color(0xFF006B7A);
  static const olive = Color(0xFF8B6914);
  static const slate = Color(0xFF3D4955);
  static const nullGray = Color(0xFF9A9A9A);
}

/// Clean geometric sans-serif — closest readily available to the Univers /
/// DIN family Aperture Science branding uses. Falls back through the stack
/// if a host platform lacks the primary face.
const String _portalUiFontFamily = 'Helvetica Neue';

const AppPalette portalPalette = AppPalette(
  surface: _PortalColors.labWhite,
  surfaceRaised: _PortalColors.labOffWhite,
  surfaceRecessed: _PortalColors.labPanel,
  field: _PortalColors.labWhite,
  fieldDisabled: _PortalColors.labDisabled,
  border: _PortalColors.seam,
  borderStrong: _PortalColors.seamStrong,
  text: _PortalColors.text,
  mutedText: _PortalColors.mutedText,
  accent: _PortalColors.portalOrange,
  onAccent: _PortalColors.labWhite,
  accentSoft: _PortalColors.portalOrangeSoft,
  rowHover: _PortalColors.portalBlueSoft,
  rowSelected: _PortalColors.portalBlueSelected,
  rowEditing: _PortalColors.editingTint,
  rowReadOnly: _PortalColors.labPanel,
  typeString: _PortalColors.burntOrange,
  typeNumber: _PortalColors.deepBlue,
  typeBool: _PortalColors.apertureGreen,
  typeDate: _PortalColors.purple,
  typeUuid: _PortalColors.teal,
  typeJson: _PortalColors.olive,
  typeBinary: _PortalColors.slate,
  typeNull: _PortalColors.nullGray,
  // Unused under [ChromeKind.flat] but kept for completeness.
  bevelHighlight: _PortalColors.labWhite,
  bevelShadow: _PortalColors.seam,
  chrome: ChromeKind.flat,
  cornerRadius: 2,
  uiFontFamily: _portalUiFontFamily,
  monoFontFamily: 'Menlo',
  bodyFontSize: 12,
  smallFontSize: 11,
);

/// Builds the Portal / Aperture Science [ThemeData]. The optional
/// [fontFamily] overrides the default `Helvetica Neue` so consumers can
/// fall back to the platform UI font or a bundled face.
ThemeData buildPortalTheme({String? fontFamily}) {
  final palette = fontFamily == null
      ? portalPalette
      : portalPalette.copyWith(uiFontFamily: fontFamily);
  final radius = BorderRadius.circular(palette.cornerRadius);

  OutlineInputBorder outline(Color color) => OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: color, width: 1),
  );

  final bodyText = palette.bodyText;
  final smallText = palette.smallText;
  final boldText = palette.boldText;

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    primaryColor: palette.accent,
    canvasColor: palette.surface,
    scaffoldBackgroundColor: palette.surface,
    cardColor: palette.surfaceRaised,
    dividerColor: palette.border,
    hintColor: palette.mutedText,
    splashFactory: InkSparkle.splashFactory,
    highlightColor: palette.accent.withValues(alpha: 0.10),
    hoverColor: palette.rowHover,
    focusColor: palette.accent.withValues(alpha: 0.18),
    fontFamily: palette.uiFontFamily,
    extensions: [palette],
    textTheme: TextTheme(
      bodyLarge: bodyText,
      bodyMedium: bodyText,
      bodySmall: smallText,
      labelLarge: bodyText,
      labelMedium: bodyText,
      labelSmall: smallText,
      titleLarge: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        height: 1.2,
      ),
      titleMedium: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: palette.bodyFontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
        height: 1.2,
      ),
      titleSmall: boldText,
    ),
    colorScheme: const ColorScheme.light(
      primary: _PortalColors.portalOrange,
      onPrimary: _PortalColors.labWhite,
      secondary: _PortalColors.portalBlue,
      onSecondary: _PortalColors.labWhite,
      surface: _PortalColors.labWhite,
      onSurface: _PortalColors.text,
      surfaceContainer: _PortalColors.labPanel,
      surfaceContainerHigh: _PortalColors.labOffWhite,
      surfaceContainerHighest: _PortalColors.labOffWhite,
      error: Color(0xFFC1272D),
      onError: _PortalColors.labWhite,
      tertiaryContainer: _PortalColors.portalBlueSoft,
      onTertiaryContainer: _PortalColors.text,
      errorContainer: Color(0xFFFFE0E0),
      onErrorContainer: Color(0xFF8B0000),
      primaryContainer: _PortalColors.portalOrangeSoft,
      onPrimaryContainer: _PortalColors.text,
      outline: _PortalColors.seam,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: palette.border, width: 1),
      ),
      titleTextStyle: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
      contentTextStyle: bodyText,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.field,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: outline(palette.border),
      enabledBorder: outline(palette.border),
      focusedBorder: outline(palette.accent),
      labelStyle: TextStyle(
        color: palette.mutedText,
        fontFamily: palette.uiFontFamily,
        fontSize: palette.bodyFontSize,
      ),
      hintStyle: TextStyle(
        color: palette.mutedText,
        fontFamily: palette.uiFontFamily,
        fontSize: palette.bodyFontSize,
      ),
      floatingLabelStyle: TextStyle(
        color: palette.accent,
        fontFamily: palette.uiFontFamily,
        fontSize: palette.bodyFontSize,
        fontWeight: FontWeight.w600,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: palette.border, width: 1),
      ),
      textStyle: bodyText,
      elevation: 4,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.surfaceRaised),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: palette.border, width: 1),
          ),
        ),
        elevation: const WidgetStatePropertyAll(4),
      ),
    ),
    cardTheme: CardThemeData(
      color: palette.surfaceRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: palette.border, width: 1),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        shape: RoundedRectangleBorder(borderRadius: radius),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        textStyle: TextStyle(
          color: palette.onAccent,
          fontFamily: palette.uiFontFamily,
          fontSize: palette.bodyFontSize,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        shape: RoundedRectangleBorder(borderRadius: radius),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        textStyle: TextStyle(
          color: palette.onAccent,
          fontFamily: palette.uiFontFamily,
          fontSize: palette.bodyFontSize,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.text,
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: bodyText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: palette.text,
        shape: RoundedRectangleBorder(borderRadius: radius),
        backgroundColor: Colors.transparent,
      ),
    ),
    iconTheme: IconThemeData(color: palette.text, size: 16),
    dividerTheme: DividerThemeData(
      color: palette.border,
      space: 1,
      thickness: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.accent,
      contentTextStyle: TextStyle(
        color: palette.onAccent,
        fontFamily: palette.uiFontFamily,
        fontSize: palette.bodyFontSize,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: radius),
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.accent,
      linearTrackColor: palette.border,
      circularTrackColor: palette.border,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.surfaceRecessed,
      foregroundColor: palette.text,
      elevation: 0,
      shape: Border(bottom: BorderSide(color: palette.border, width: 1)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: palette.text, borderRadius: radius),
      textStyle: TextStyle(
        color: palette.surface,
        fontFamily: palette.uiFontFamily,
        fontSize: palette.smallFontSize,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return palette.onAccent;
        return palette.surface;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return palette.accent;
        return palette.border;
      }),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
      minVerticalPadding: 2,
      dense: true,
      textColor: palette.text,
      iconColor: palette.text,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.surfaceRaised),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        elevation: const WidgetStatePropertyAll(4),
      ),
      textStyle: bodyText,
    ),
  );
}

/// [AppTheme] wrapper around [buildPortalTheme] for theme registries.
class PortalTheme implements AppTheme {
  const PortalTheme({this.fontFamily});

  /// Overrides the default `Helvetica Neue` — pass any platform font.
  final String? fontFamily;

  @override
  String get name => 'Portal';

  @override
  ThemeData get themeData => buildPortalTheme(fontFamily: fontFamily);
}
