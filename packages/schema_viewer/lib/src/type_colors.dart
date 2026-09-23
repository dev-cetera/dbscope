import 'package:flutter/material.dart';

/// Type-family hues used to tint the right-hand column on a schema card.
/// Mirrors admin_site/src/lib/typeColors.ts: same hue/saturation per
/// family, lightness flips with the brightness of the surrounding
/// theme. The exact RGB doesn't matter — visual identity per family
/// across the diagram does.
enum SchemaTypeFamily {
  intFamily,
  floatFamily,
  boolFamily,
  textFamily,
  timeFamily,
  uuidFamily,
  jsonFamily,
  binaryFamily,
  enumFamily,
  arrayFamily,
  geoFamily,
  otherFamily,
}

class _Hue {
  final double h;
  final double s;
  const _Hue(this.h, this.s);
}

const Map<SchemaTypeFamily, _Hue> _familyHue = {
  SchemaTypeFamily.intFamily: _Hue(199, 0.80),
  SchemaTypeFamily.floatFamily: _Hue(229, 0.80),
  SchemaTypeFamily.boolFamily: _Hue(0, 0.75),
  SchemaTypeFamily.textFamily: _Hue(38, 0.85),
  SchemaTypeFamily.timeFamily: _Hue(142, 0.60),
  SchemaTypeFamily.uuidFamily: _Hue(326, 0.70),
  SchemaTypeFamily.jsonFamily: _Hue(262, 0.65),
  SchemaTypeFamily.binaryFamily: _Hue(25, 0.10),
  SchemaTypeFamily.enumFamily: _Hue(27, 0.85),
  SchemaTypeFamily.arrayFamily: _Hue(187, 0.75),
  SchemaTypeFamily.geoFamily: _Hue(166, 0.60),
  SchemaTypeFamily.otherFamily: _Hue(0, 0.0),
};

SchemaTypeFamily classifyTypeName(String? rawTypeLabel) {
  if (rawTypeLabel == null) return SchemaTypeFamily.otherFamily;
  final s = rawTypeLabel.trim();
  if (s.isEmpty) return SchemaTypeFamily.otherFamily;
  if (RegExp(r'\[\]\s*$').hasMatch(s)) return SchemaTypeFamily.arrayFamily;
  if (RegExp(r'^(small|big|tiny|medium)?int(eger)?\d*$', caseSensitive: false)
      .hasMatch(s)) {
    return SchemaTypeFamily.intFamily;
  }
  if (RegExp(r'^serial\d*$', caseSensitive: false).hasMatch(s)) {
    return SchemaTypeFamily.intFamily;
  }
  if (s.toLowerCase() == 'bigserial') return SchemaTypeFamily.intFamily;
  if (RegExp(
    r'^(numeric|decimal|real|double precision|float\d*)$',
    caseSensitive: false,
  ).hasMatch(s)) {
    return SchemaTypeFamily.floatFamily;
  }
  if (RegExp(r'^bool(ean)?$', caseSensitive: false).hasMatch(s)) {
    return SchemaTypeFamily.boolFamily;
  }
  if (RegExp(
    r'^(text|varchar|char|character( varying)?|citext|name)$',
    caseSensitive: false,
  ).hasMatch(s)) {
    return SchemaTypeFamily.textFamily;
  }
  if (RegExp(
    r'^(timestamp|timestamptz|date|time|timetz|interval)',
    caseSensitive: false,
  ).hasMatch(s)) {
    return SchemaTypeFamily.timeFamily;
  }
  if (s.toLowerCase() == 'uuid') return SchemaTypeFamily.uuidFamily;
  if (RegExp(r'^(json|jsonb|hstore)$', caseSensitive: false).hasMatch(s)) {
    return SchemaTypeFamily.jsonFamily;
  }
  if (s.toLowerCase() == 'bytea') return SchemaTypeFamily.binaryFamily;
  if (RegExp(
    r'^(geometry|geography|point|polygon|line|box|circle|path|lseg)',
    caseSensitive: false,
  ).hasMatch(s)) {
    return SchemaTypeFamily.geoFamily;
  }
  return SchemaTypeFamily.otherFamily;
}

Color colorForType(String? rawTypeLabel, {required bool darkMode}) {
  final fam = classifyTypeName(rawTypeLabel);
  final hue = _familyHue[fam]!;
  final l = darkMode ? 0.74 : 0.36;
  return HSLColor.fromAHSL(1.0, hue.h, hue.s, l).toColor();
}
