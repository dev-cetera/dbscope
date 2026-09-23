import 'package:flutter/material.dart';

/// Drawing strategy for chrome elements (bevels, fields, tabs).
///
/// `bevel` paints 4-sided 1px highlight/shadow borders à la Windows 95.
/// `flat` paints a single 1px [AppPalette.border] line with rounded corners.
enum ChromeKind { bevel, flat }

/// Semantic role colors + shape primitives that both the Win95 and VS Code
/// Dark Modern themes implement. Code outside of the package should reach
/// for these via [AppPalette.of] rather than hard-coded constants.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  // Backgrounds.
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceRecessed;

  // Form fields.
  final Color field;
  final Color fieldDisabled;

  // Borders.
  final Color border;
  final Color borderStrong;

  // Text.
  final Color text;
  final Color mutedText;

  // Accent / selection.
  final Color accent;
  final Color onAccent;
  final Color accentSoft;

  // Data-grid row states.
  final Color rowHover;
  final Color rowSelected;
  final Color rowEditing;
  final Color rowReadOnly;

  // Data-type cell text colors. Applied per-column in data grids so
  // values can be syntax-highlighted by their type family.
  final Color typeString;
  final Color typeNumber;
  final Color typeBool;
  final Color typeDate;
  final Color typeUuid;
  final Color typeJson;
  final Color typeBinary;
  final Color typeNull;

  // Bevel decoration (only used when [chrome] == [ChromeKind.bevel]).
  final Color bevelHighlight;
  final Color bevelShadow;

  // Shape primitives.
  final ChromeKind chrome;
  final double cornerRadius;

  // Typography.
  final String uiFontFamily;
  final String monoFontFamily;
  final double bodyFontSize;
  final double smallFontSize;

  const AppPalette({
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceRecessed,
    required this.field,
    required this.fieldDisabled,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.mutedText,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.rowHover,
    required this.rowSelected,
    required this.rowEditing,
    required this.rowReadOnly,
    required this.typeString,
    required this.typeNumber,
    required this.typeBool,
    required this.typeDate,
    required this.typeUuid,
    required this.typeJson,
    required this.typeBinary,
    required this.typeNull,
    required this.bevelHighlight,
    required this.bevelShadow,
    required this.chrome,
    required this.cornerRadius,
    required this.uiFontFamily,
    required this.monoFontFamily,
    required this.bodyFontSize,
    required this.smallFontSize,
  });

  static AppPalette of(BuildContext context) {
    final ext = Theme.of(context).extension<AppPalette>();
    assert(ext != null, 'AppPalette missing from ThemeData.extensions');
    return ext!;
  }

  bool get isBevel => chrome == ChromeKind.bevel;

  TextStyle get bodyText => TextStyle(
    color: text,
    fontSize: bodyFontSize,
    fontFamily: uiFontFamily,
    height: 1.2,
  );

  TextStyle get smallText => TextStyle(
    color: text,
    fontSize: smallFontSize,
    fontFamily: uiFontFamily,
    height: 1.2,
  );

  TextStyle get boldText => TextStyle(
    color: text,
    fontSize: bodyFontSize,
    fontFamily: uiFontFamily,
    fontWeight: FontWeight.bold,
    height: 1.2,
  );

  @override
  AppPalette copyWith({
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceRecessed,
    Color? field,
    Color? fieldDisabled,
    Color? border,
    Color? borderStrong,
    Color? text,
    Color? mutedText,
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? rowHover,
    Color? rowSelected,
    Color? rowEditing,
    Color? rowReadOnly,
    Color? typeString,
    Color? typeNumber,
    Color? typeBool,
    Color? typeDate,
    Color? typeUuid,
    Color? typeJson,
    Color? typeBinary,
    Color? typeNull,
    Color? bevelHighlight,
    Color? bevelShadow,
    ChromeKind? chrome,
    double? cornerRadius,
    String? uiFontFamily,
    String? monoFontFamily,
    double? bodyFontSize,
    double? smallFontSize,
  }) {
    return AppPalette(
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceRecessed: surfaceRecessed ?? this.surfaceRecessed,
      field: field ?? this.field,
      fieldDisabled: fieldDisabled ?? this.fieldDisabled,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      text: text ?? this.text,
      mutedText: mutedText ?? this.mutedText,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      accentSoft: accentSoft ?? this.accentSoft,
      rowHover: rowHover ?? this.rowHover,
      rowSelected: rowSelected ?? this.rowSelected,
      rowEditing: rowEditing ?? this.rowEditing,
      rowReadOnly: rowReadOnly ?? this.rowReadOnly,
      typeString: typeString ?? this.typeString,
      typeNumber: typeNumber ?? this.typeNumber,
      typeBool: typeBool ?? this.typeBool,
      typeDate: typeDate ?? this.typeDate,
      typeUuid: typeUuid ?? this.typeUuid,
      typeJson: typeJson ?? this.typeJson,
      typeBinary: typeBinary ?? this.typeBinary,
      typeNull: typeNull ?? this.typeNull,
      bevelHighlight: bevelHighlight ?? this.bevelHighlight,
      bevelShadow: bevelShadow ?? this.bevelShadow,
      chrome: chrome ?? this.chrome,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      uiFontFamily: uiFontFamily ?? this.uiFontFamily,
      monoFontFamily: monoFontFamily ?? this.monoFontFamily,
      bodyFontSize: bodyFontSize ?? this.bodyFontSize,
      smallFontSize: smallFontSize ?? this.smallFontSize,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceRecessed: Color.lerp(surfaceRecessed, other.surfaceRecessed, t)!,
      field: Color.lerp(field, other.field, t)!,
      fieldDisabled: Color.lerp(fieldDisabled, other.fieldDisabled, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      text: Color.lerp(text, other.text, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      rowHover: Color.lerp(rowHover, other.rowHover, t)!,
      rowSelected: Color.lerp(rowSelected, other.rowSelected, t)!,
      rowEditing: Color.lerp(rowEditing, other.rowEditing, t)!,
      rowReadOnly: Color.lerp(rowReadOnly, other.rowReadOnly, t)!,
      typeString: Color.lerp(typeString, other.typeString, t)!,
      typeNumber: Color.lerp(typeNumber, other.typeNumber, t)!,
      typeBool: Color.lerp(typeBool, other.typeBool, t)!,
      typeDate: Color.lerp(typeDate, other.typeDate, t)!,
      typeUuid: Color.lerp(typeUuid, other.typeUuid, t)!,
      typeJson: Color.lerp(typeJson, other.typeJson, t)!,
      typeBinary: Color.lerp(typeBinary, other.typeBinary, t)!,
      typeNull: Color.lerp(typeNull, other.typeNull, t)!,
      bevelHighlight: Color.lerp(bevelHighlight, other.bevelHighlight, t)!,
      bevelShadow: Color.lerp(bevelShadow, other.bevelShadow, t)!,
      chrome: t < 0.5 ? chrome : other.chrome,
      cornerRadius: cornerRadius + (other.cornerRadius - cornerRadius) * t,
      uiFontFamily: t < 0.5 ? uiFontFamily : other.uiFontFamily,
      monoFontFamily: t < 0.5 ? monoFontFamily : other.monoFontFamily,
      bodyFontSize: bodyFontSize + (other.bodyFontSize - bodyFontSize) * t,
      smallFontSize: smallFontSize + (other.smallFontSize - smallFontSize) * t,
    );
  }
}
