import 'package:flutter/material.dart';

/// Fixed 32-colour palette. Hues are golden-ratio spaced so adjacent
/// palette indices land far apart on the colour wheel — that gives
/// per-row collision shifters an easy way to make neighbouring tables
/// look maximally distinct just by bumping their index by one.
final List<Color> kRelationshipPalette = List.unmodifiable(
  List.generate(32, (i) {
    final hue = (i * 137.508) % 360;
    final s = 0.55 + (i % 3) * 0.05;
    final l = 0.50 + ((i ~/ 5) % 2) * 0.10;
    return HSLColor.fromAHSL(1.0, hue, s, l).toColor();
  }),
);

/// Index into [kRelationshipPalette] for [tableKey]. Hashes the reversed
/// string so alphabetically adjacent siblings (`users`, `users_log`)
/// don't land in the same bucket from a shared prefix — their reverses
/// diverge at the very first byte of the hash input.
int colorIndexForTable(String tableKey) {
  int h = 2166136261;
  for (var i = tableKey.length - 1; i >= 0; i--) {
    h = ((h ^ tableKey.codeUnitAt(i)) * 16777619) & 0xFFFFFFFF;
  }
  return h % kRelationshipPalette.length;
}

/// Stable per-name colour. Used to tint card headers, FK row text, and
/// the gradient that fills each edge.
Color colorForTable(String tableKey) =>
    kRelationshipPalette[colorIndexForTable(tableKey)];

/// Walks [tableKeysInOrder] (the order they appear in a list) and
/// assigns each a palette colour, shifting by a coprime stride whenever
/// a table would otherwise share its predecessor's colour. The result
/// is a stable-per-name colour that's also guaranteed not to repeat
/// between two rows the user can see next to each other.
Map<String, Color> buildTableColorMap(Iterable<String> tableKeysInOrder) {
  final out = <String, Color>{};
  int? prevIdx;
  for (final key in tableKeysInOrder) {
    var idx = colorIndexForTable(key);
    if (prevIdx != null && idx == prevIdx) {
      idx = (idx + 17) % kRelationshipPalette.length;
    }
    out[key] = kRelationshipPalette[idx];
    prevIdx = idx;
  }
  return out;
}
