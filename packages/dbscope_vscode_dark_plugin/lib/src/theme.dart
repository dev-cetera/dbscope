import 'package:flutter/material.dart';

import 'package:widgets/widgets.dart';

/// VS Code "Dark Modern" palette values. Constants live here; widgets read
/// role-based colors via [AppPalette.of].
class _VsCodeDark {
  // Workbench surfaces.
  static const editorBg = Color(0xFF1F1F1F); // editor.background
  static const sideBarBg = Color(0xFF181818); // sideBar.background
  static const titleBarBg = Color(0xFF181818); // titleBar.activeBackground
  static const tabActiveBg = Color(0xFF1F1F1F);

  // Inputs / fields.
  static const inputBg = Color(0xFF313131);
  static const inputDisabledBg = Color(0xFF2A2A2A);

  // Borders.
  static const border = Color(0xFF2B2B2B);
  static const borderStrong = Color(0xFF454545);

  // Text.
  static const fg = Color(0xFFCCCCCC);
  static const descriptionFg = Color(0xFF9D9D9D);

  // Accent / focus / selection.
  static const accent = Color(0xFF0078D4);
  static const accentText = Color(0xFFFFFFFF);
  static const accentSoft = Color(0xFF04395E); // list.activeSelectionBackground

  // List / row states.
  static const listHover = Color(0xFF2A2D2E); // list.hoverBackground
  static const listActiveSel = Color(0xFF04395E);

  // Editor highlight tints.
  static const editingTint = Color(0xFF3C3C00); // soft amber on dark

  // Syntax token colors from the Dark Modern theme.
  static const tokenString = Color(0xFFCE9178); // strings
  static const tokenNumber = Color(0xFFB5CEA8); // numeric literals
  static const tokenKeyword = Color(0xFF569CD6); // true / false / null keyword
  static const tokenType = Color(0xFF4EC9B0); // class / type names
  static const tokenFunction = Color(0xFFDCDCAA); // function names
  static const tokenVariable = Color(0xFF9CDCFE); // variables / properties
  static const tokenRegex = Color(0xFFD7BA7D); // regex / dates feel
  static const tokenComment = Color(0xFF6A9955); // comments
}

const AppPalette vsCodeDarkPalette = AppPalette(
  surface: _VsCodeDark.editorBg,
  surfaceRaised: _VsCodeDark.tabActiveBg,
  surfaceRecessed: _VsCodeDark.sideBarBg,
  field: _VsCodeDark.inputBg,
  fieldDisabled: _VsCodeDark.inputDisabledBg,
  border: _VsCodeDark.border,
  borderStrong: _VsCodeDark.borderStrong,
  text: _VsCodeDark.fg,
  mutedText: _VsCodeDark.descriptionFg,
  accent: _VsCodeDark.accent,
  onAccent: _VsCodeDark.accentText,
  accentSoft: _VsCodeDark.accentSoft,
  rowHover: _VsCodeDark.listHover,
  rowSelected: _VsCodeDark.listActiveSel,
  rowEditing: _VsCodeDark.editingTint,
  rowReadOnly: _VsCodeDark.inputDisabledBg,
  typeString: _VsCodeDark.tokenString,
  typeNumber: _VsCodeDark.tokenNumber,
  typeBool: _VsCodeDark.tokenKeyword,
  typeDate: _VsCodeDark.tokenRegex,
  typeUuid: _VsCodeDark.tokenType,
  typeJson: _VsCodeDark.tokenFunction,
  typeBinary: _VsCodeDark.tokenVariable,
  typeNull: _VsCodeDark.tokenComment,
  // Unused under [ChromeKind.flat] but kept for completeness.
  bevelHighlight: _VsCodeDark.border,
  bevelShadow: _VsCodeDark.border,
  chrome: ChromeKind.flat,
  cornerRadius: 4,
  uiFontFamily: '.AppleSystemUIFont',
  monoFontFamily: 'Menlo',
  bodyFontSize: 13,
  smallFontSize: 12,
);

/// Builds the VS Code Dark Modern [ThemeData]. The optional [fontFamily]
/// overrides the default `.AppleSystemUIFont`.
ThemeData buildVsCodeDarkTheme({String? fontFamily}) {
  final palette = fontFamily == null
      ? vsCodeDarkPalette
      : vsCodeDarkPalette.copyWith(uiFontFamily: fontFamily);
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
    brightness: Brightness.dark,
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
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
      titleMedium: boldText,
      titleSmall: boldText,
    ),
    colorScheme: const ColorScheme.dark(
      primary: _VsCodeDark.accent,
      onPrimary: _VsCodeDark.accentText,
      secondary: _VsCodeDark.accent,
      onSecondary: _VsCodeDark.accentText,
      surface: _VsCodeDark.editorBg,
      onSurface: _VsCodeDark.fg,
      surfaceContainer: _VsCodeDark.sideBarBg,
      surfaceContainerHigh: _VsCodeDark.tabActiveBg,
      surfaceContainerHighest: _VsCodeDark.tabActiveBg,
      error: Color(0xFFF48771),
      onError: _VsCodeDark.accentText,
      tertiaryContainer: _VsCodeDark.accentSoft,
      onTertiaryContainer: _VsCodeDark.fg,
      errorContainer: Color(0xFF5A1D1D),
      onErrorContainer: Color(0xFFFFB4AB),
      primaryContainer: _VsCodeDark.accentSoft,
      onPrimaryContainer: _VsCodeDark.fg,
      outline: _VsCodeDark.border,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: radius),
      titleTextStyle: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w600,
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
        textStyle: boldText,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        shape: RoundedRectangleBorder(borderRadius: radius),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        textStyle: boldText,
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
      backgroundColor: palette.surfaceRaised,
      contentTextStyle: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: palette.bodyFontSize,
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
      backgroundColor: _VsCodeDark.titleBarBg,
      foregroundColor: palette.text,
      elevation: 0,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: radius,
        border: Border.all(color: palette.border, width: 1),
      ),
      textStyle: TextStyle(
        color: palette.text,
        fontFamily: palette.uiFontFamily,
        fontSize: palette.smallFontSize,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return palette.onAccent;
        return palette.mutedText;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return palette.accent;
        return palette.surfaceRecessed;
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

/// [AppTheme] wrapper around [buildVsCodeDarkTheme] for theme registries.
class VsCodeDarkTheme implements AppTheme {
  const VsCodeDarkTheme({this.fontFamily});

  /// Overrides the default `.AppleSystemUIFont` — pass any platform font.
  final String? fontFamily;

  @override
  String get name => 'VS Code Dark';

  @override
  ThemeData get themeData => buildVsCodeDarkTheme(fontFamily: fontFamily);
}
