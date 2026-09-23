import 'package:flutter/material.dart';

import 'package:widgets/widgets.dart';

/// Windows 95 palette values. Kept as a private collection of constants;
/// widgets read role-based colors via [AppPalette.of].
class _Win95Colors {
  static const background = Color(0xFFC0C0C0);
  static const highlight = Color(0xFFFFFFFF);
  static const light = Color(0xFFDFDFDF);
  static const shadow = Color(0xFF808080);
  static const darkShadow = Color(0xFF000000);
  static const titleBar = Color(0xFF000080);
  static const titleBarText = Color(0xFFFFFFFF);
  static const text = Color(0xFF000000);
  static const disabledText = Color(0xFF808080);
  static const field = Color(0xFFFFFFFF);
  static const tooltip = Color(0xFFFFFFE1);

  // Grid row states - tuned for the white cell background.
  static const rowHover = Color(0xFFE3EFFB);
  static const rowSelected = Color(0xFFB0D6FF);
  static const rowEditing = Color(0xFFFFFFCC);
  static const rowReadOnly = Color(0xFFE8E8E8);

  // Classic Win9x 16-color palette, picked for legibility on white cells.
  static const navy = Color(0xFF000080);
  static const maroon = Color(0xFF800000);
  static const teal = Color(0xFF008080);
  static const purple = Color(0xFF800080);
  static const darkGreen = Color(0xFF006400);
  static const olive = Color(0xFF808000);
  static const slate = Color(0xFF404040);
}

/// Font family for the bundled MS Sans Serif TTF. Flutter prefixes fonts
/// declared by a package with `packages/<name>/` when consumers reference
/// them without the explicit `package:` argument.
const String _win95UiFontFamily = 'packages/widgets/MS Sans Serif';

const AppPalette win95Palette = AppPalette(
  surface: _Win95Colors.background,
  surfaceRaised: _Win95Colors.light,
  surfaceRecessed: _Win95Colors.shadow,
  field: _Win95Colors.field,
  fieldDisabled: _Win95Colors.rowReadOnly,
  border: _Win95Colors.shadow,
  borderStrong: _Win95Colors.darkShadow,
  text: _Win95Colors.text,
  mutedText: Color(0xFF606060),
  accent: _Win95Colors.titleBar,
  onAccent: _Win95Colors.titleBarText,
  accentSoft: Color(0x22000080),
  rowHover: _Win95Colors.rowHover,
  rowSelected: _Win95Colors.rowSelected,
  rowEditing: _Win95Colors.rowEditing,
  rowReadOnly: _Win95Colors.rowReadOnly,
  typeString: _Win95Colors.maroon,
  typeNumber: _Win95Colors.navy,
  typeBool: _Win95Colors.teal,
  typeDate: _Win95Colors.purple,
  typeUuid: _Win95Colors.darkGreen,
  typeJson: _Win95Colors.olive,
  typeBinary: _Win95Colors.slate,
  typeNull: _Win95Colors.disabledText,
  bevelHighlight: _Win95Colors.highlight,
  bevelShadow: _Win95Colors.shadow,
  chrome: ChromeKind.bevel,
  cornerRadius: 0,
  uiFontFamily: _win95UiFontFamily,
  monoFontFamily: 'Menlo',
  bodyFontSize: 11,
  smallFontSize: 10,
);

/// Builds the Windows 95 [ThemeData]. The optional [fontFamily] overrides
/// the bundled MS Sans Serif default so consumers that want the platform UI
/// font (e.g. system-ui on macOS) can opt out without forking the theme.
ThemeData buildWin95Theme({String? fontFamily}) {
  final palette = fontFamily == null
      ? win95Palette
      : win95Palette.copyWith(uiFontFamily: fontFamily);
  const outline = OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(color: _Win95Colors.shadow, width: 1),
  );
  const focusOutline = OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(color: _Win95Colors.titleBar, width: 1),
  );

  final bodyText = palette.bodyText;
  final smallText = palette.smallText;
  final boldText = palette.boldText;

  return ThemeData(
    useMaterial3: false,
    brightness: Brightness.light,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    primaryColor: palette.accent,
    canvasColor: palette.surface,
    scaffoldBackgroundColor: palette.surface,
    cardColor: palette.surface,
    dividerColor: palette.border,
    hintColor: palette.mutedText,
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x22000080),
    splashColor: Colors.transparent,
    hoverColor: const Color(0x11000080),
    focusColor: const Color(0x33000080),
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
        fontSize: 13,
        fontWeight: FontWeight.bold,
        height: 1.2,
      ),
      titleMedium: boldText,
      titleSmall: boldText,
    ),
    colorScheme: const ColorScheme.light(
      primary: _Win95Colors.titleBar,
      onPrimary: _Win95Colors.titleBarText,
      secondary: _Win95Colors.titleBar,
      onSecondary: _Win95Colors.titleBarText,
      surface: _Win95Colors.background,
      onSurface: _Win95Colors.text,
      surfaceContainer: _Win95Colors.background,
      surfaceContainerHigh: _Win95Colors.background,
      surfaceContainerHighest: _Win95Colors.background,
      error: Color(0xFF8B0000),
      onError: _Win95Colors.titleBarText,
      tertiaryContainer: _Win95Colors.titleBar,
      onTertiaryContainer: _Win95Colors.titleBarText,
      errorContainer: Color(0xFFFFE0E0),
      onErrorContainer: Color(0xFF8B0000),
      primaryContainer: _Win95Colors.titleBar,
      onPrimaryContainer: _Win95Colors.titleBarText,
      outline: _Win95Colors.shadow,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      titleTextStyle: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: 13,
        fontWeight: FontWeight.bold,
      ),
      contentTextStyle: bodyText,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.field,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      border: outline,
      enabledBorder: outline,
      focusedBorder: focusOutline,
      labelStyle: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: 12,
      ),
      hintStyle: TextStyle(
        color: palette.mutedText,
        fontFamily: palette.uiFontFamily,
        fontSize: 12,
      ),
      floatingLabelStyle: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: 12,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: _Win95Colors.darkShadow, width: 1),
      ),
      textStyle: bodyText,
      elevation: 0,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(_Win95Colors.background),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
        elevation: WidgetStatePropertyAll(0),
      ),
    ),
    cardTheme: CardThemeData(
      color: palette.surface,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: palette.surface,
        foregroundColor: palette.text,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        elevation: 0,
        side: const BorderSide(color: _Win95Colors.darkShadow, width: 1),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        textStyle: boldText,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.surface,
        foregroundColor: palette.text,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        elevation: 0,
        side: const BorderSide(color: _Win95Colors.darkShadow, width: 1),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        textStyle: boldText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.text,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        textStyle: bodyText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: palette.text,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
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
        fontSize: 12,
      ),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      behavior: SnackBarBehavior.fixed,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.accent,
      linearTrackColor: palette.border,
      circularTrackColor: palette.border,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.accent,
      foregroundColor: palette.onAccent,
      elevation: 0,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: const BoxDecoration(
        color: _Win95Colors.tooltip,
        border: Border.fromBorderSide(
          BorderSide(color: _Win95Colors.darkShadow, width: 1),
        ),
      ),
      textStyle: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: 11,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return palette.accent;
        return palette.surface;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) {
          return palette.accent.withValues(alpha: 0.4);
        }
        return palette.border;
      }),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      minVerticalPadding: 0,
      dense: true,
      textColor: palette.text,
      iconColor: palette.text,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(_Win95Colors.background),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
        elevation: WidgetStatePropertyAll(0),
      ),
      textStyle: bodyText,
    ),
  );
}

/// [AppTheme] wrapper around [buildWin95Theme] for theme registries.
class Win95Theme implements AppTheme {
  const Win95Theme({this.fontFamily});

  /// Overrides the bundled MS Sans Serif default — pass e.g. `'system-ui'`
  /// to fall back to the platform UI font.
  final String? fontFamily;

  @override
  String get name => 'Win95';

  @override
  ThemeData get themeData => buildWin95Theme(fontFamily: fontFamily);
}
