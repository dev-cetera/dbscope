import 'dart:convert';

import 'package:flutter/material.dart';
import 'palette.dart';

/// Theme-aware JSON syntax highlighter.
///
/// Pretty-prints the parsed JSON (2-space indent) and emits coloured
/// [TextSpan]s for keys, strings, numbers, booleans, null, and
/// punctuation. Colours come from [AppPalette] so the same widget works
/// under Win95 and VS Code Dark.
///
/// When the input isn't valid JSON, returns a single plain span so the
/// caller can still display the raw text without crashing.
List<InlineSpan> highlightJson(String input, AppPalette palette) {
  dynamic decoded;
  try {
    decoded = jsonDecode(input);
  } catch (_) {
    return [TextSpan(text: input, style: _base(palette))];
  }
  final spans = <InlineSpan>[];
  _emit(spans, decoded, palette, 0, inline: false);
  return spans;
}

/// Single-line variant for grid cells and other tight surfaces. Renders
/// the same JSON value as [highlightJson] but without newlines or
/// indentation, so the host can render via `Text.rich(maxLines: 1,
/// overflow: TextOverflow.ellipsis)` without leaking the layout.
///
/// [style] overrides the base text style — useful when the cell wants a
/// specific font size / family that differs from the multi-line viewer
/// defaults.
List<InlineSpan> highlightJsonInline(
  String input,
  AppPalette palette, {
  TextStyle? style,
}) {
  dynamic decoded;
  try {
    decoded = jsonDecode(input);
  } catch (_) {
    return [TextSpan(text: input, style: style ?? _base(palette))];
  }
  final spans = <InlineSpan>[];
  _emit(spans, decoded, palette, 0, inline: true, override: style);
  return spans;
}

TextStyle _base(AppPalette p) => TextStyle(
  fontFamily: p.monoFontFamily,
  fontSize: p.bodyFontSize,
  color: p.text,
  height: 1.4,
);

TextStyle _styleWith(
  AppPalette p,
  Color c, {
  FontWeight? weight,
  TextStyle? override,
}) {
  final base = override ?? _base(p);
  return base.copyWith(color: c, fontWeight: weight);
}

void _emit(
  List<InlineSpan> spans,
  Object? value,
  AppPalette p,
  int indent, {
  required bool inline,
  TextStyle? override,
}) {
  final newline = inline ? '' : '\n';
  final indentNext = inline ? '' : ' ' * (indent + 1);
  final indentClose = inline ? '' : ' ' * indent;
  final keyColonSep = inline ? ':' : ': ';
  final commaSep = inline ? ',' : ',';
  final spaceAfterComma = inline ? ' ' : '';

  if (value is Map) {
    if (value.isEmpty) {
      spans.add(
        TextSpan(text: '{}', style: _styleWith(p, p.text, override: override)),
      );
      return;
    }
    spans.add(
      TextSpan(
        text: '{$newline',
        style: _styleWith(p, p.text, override: override),
      ),
    );
    final entries = value.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      if (!inline) {
        spans.add(TextSpan(text: indentNext, style: override ?? _base(p)));
      }
      spans.add(
        TextSpan(
          text: jsonEncode(entries[i].key),
          style: _styleWith(
            p,
            p.accent,
            weight: FontWeight.w600,
            override: override,
          ),
        ),
      );
      spans.add(
        TextSpan(
          text: keyColonSep,
          style: _styleWith(p, p.mutedText, override: override),
        ),
      );
      _emit(
        spans,
        entries[i].value,
        p,
        indent + 1,
        inline: inline,
        override: override,
      );
      if (i < entries.length - 1) {
        spans.add(
          TextSpan(
            text: '$commaSep$spaceAfterComma',
            style: _styleWith(p, p.mutedText, override: override),
          ),
        );
      }
      if (!inline) {
        spans.add(TextSpan(text: '\n', style: override ?? _base(p)));
      }
    }
    spans.add(
      TextSpan(
        text: '$indentClose}',
        style: _styleWith(p, p.text, override: override),
      ),
    );
  } else if (value is List) {
    if (value.isEmpty) {
      spans.add(
        TextSpan(text: '[]', style: _styleWith(p, p.text, override: override)),
      );
      return;
    }
    spans.add(
      TextSpan(
        text: '[$newline',
        style: _styleWith(p, p.text, override: override),
      ),
    );
    for (var i = 0; i < value.length; i++) {
      if (!inline) {
        spans.add(TextSpan(text: indentNext, style: override ?? _base(p)));
      }
      _emit(spans, value[i], p, indent + 1, inline: inline, override: override);
      if (i < value.length - 1) {
        spans.add(
          TextSpan(
            text: '$commaSep$spaceAfterComma',
            style: _styleWith(p, p.mutedText, override: override),
          ),
        );
      }
      if (!inline) {
        spans.add(TextSpan(text: '\n', style: override ?? _base(p)));
      }
    }
    spans.add(
      TextSpan(
        text: '$indentClose]',
        style: _styleWith(p, p.text, override: override),
      ),
    );
  } else if (value is String) {
    spans.add(
      TextSpan(
        text: jsonEncode(value),
        style: _styleWith(p, p.typeString, override: override),
      ),
    );
  } else if (value is num) {
    spans.add(
      TextSpan(
        text: '$value',
        style: _styleWith(p, p.typeNumber, override: override),
      ),
    );
  } else if (value is bool) {
    spans.add(
      TextSpan(
        text: '$value',
        style: _styleWith(p, p.typeBool, override: override),
      ),
    );
  } else if (value == null) {
    spans.add(
      TextSpan(
        text: 'null',
        style: _styleWith(
          p,
          p.typeNull,
          override: override,
        ).copyWith(fontStyle: FontStyle.italic),
      ),
    );
  } else {
    spans.add(TextSpan(text: value.toString(), style: override ?? _base(p)));
  }
}
