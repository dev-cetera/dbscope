import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:widgets/widgets.dart';

import '../catalog/pg_type.dart';
import 'json_dialogs.dart' show jsonSourceOf;

/// Renders a cell value with PG-type-aware color from the palette.
///
/// Used by the data grid, the navigator row-detail rows, and the
/// property inspector so all three views share one display widget.
///
/// When [detectUrl] is true (default) and the rendered text matches an
/// http(s) URL, the URL portion is underlined and tap-launchable.
class TypedValueText extends StatelessWidget {
  final Object? value;
  final PgType pgType;
  final TextOverflow overflow;
  final AlignmentGeometry? align;
  final bool detectUrl;

  /// If set, used instead of the type-derived color. Lets callers force
  /// a different role color (e.g. accent for FK chip values) without
  /// reimplementing the null/italic styling.
  final Color? colorOverride;

  /// Extra decoration applied on top of the URL detection (e.g. FK
  /// underline in non-URL strings).
  final TextDecoration? decorationOverride;

  const TypedValueText({
    super.key,
    required this.value,
    required this.pgType,
    this.overflow = TextOverflow.ellipsis,
    this.align,
    this.detectUrl = true,
    this.colorOverride,
    this.decorationOverride,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isNull = value == null;
    final color = isNull
        ? palette.typeNull
        : (colorOverride ?? colorFor(palette, pgType));
    final text = isNull ? 'NULL' : value.toString();
    final baseStyle = TextStyle(
      color: color,
      fontFamily: palette.uiFontFamily,
      fontSize: palette.bodyFontSize + 1,
      fontStyle: isNull ? FontStyle.italic : FontStyle.normal,
      height: 1.5,
      decoration: decorationOverride ?? TextDecoration.none,
    );
    final alignment =
        align ??
        (pgType == PgType.bool_ ? Alignment.center : Alignment.centerLeft);

    // JSON / JSONB cells: render compact, syntax-highlighted spans so
    // strings, numbers, booleans, null, and keys each pick up their
    // palette colour — same colour vocabulary as the popup viewer.
    // Postgres decodes json/jsonb to live Dart values (Map / List /
    // String / num / bool), so `value.toString()` here gives Dart
    // syntax (`{a: 1}`), not valid JSON. Round-trip via jsonSourceOf
    // first so the highlighter sees parseable input. Skip the path
    // when colour-override is in effect (e.g. FK chip contexts).
    if (!isNull &&
        (pgType == PgType.json || pgType == PgType.jsonb) &&
        colorOverride == null) {
      final monoStyle = baseStyle.copyWith(
        fontFamily: palette.monoFontFamily,
        fontSize: palette.bodyFontSize,
      );
      final source = jsonSourceOf(value);
      final spans = highlightJsonInline(source, palette, style: monoStyle);
      return Align(
        alignment: alignment,
        child: Text.rich(
          TextSpan(children: spans),
          overflow: overflow,
          maxLines: 1,
        ),
      );
    }

    if (isNull || !detectUrl) {
      return Align(
        alignment: alignment,
        child: Text(text, overflow: overflow, style: baseStyle),
      );
    }
    final allowEmailPhone = _isTextLike(pgType);
    final spans = _buildSpansWithUrls(
      text,
      baseStyle,
      palette,
      allowEmailPhone,
    );
    if (spans == null) {
      return Align(
        alignment: alignment,
        child: Text(text, overflow: overflow, style: baseStyle),
      );
    }
    return Align(
      alignment: alignment,
      child: Text.rich(
        TextSpan(children: spans),
        overflow: overflow,
        maxLines: 1,
      ),
    );
  }

  /// Returns the palette color for a PG type. Public so callers
  /// (typed-coloring policies elsewhere) can share the same mapping.
  static Color colorFor(AppPalette p, PgType t) {
    switch (t) {
      case PgType.text:
      case PgType.varchar:
      case PgType.name:
        return p.typeString;
      case PgType.int2:
      case PgType.int4:
      case PgType.int8:
      case PgType.numeric:
      case PgType.real:
      case PgType.doublePrecision:
        return p.typeNumber;
      case PgType.bool_:
        return p.typeBool;
      case PgType.date:
      case PgType.time:
      case PgType.timestamp:
      case PgType.timestamptz:
      case PgType.interval:
        return p.typeDate;
      case PgType.uuid:
        return p.typeUuid;
      case PgType.json:
      case PgType.jsonb:
        return p.typeJson;
      case PgType.bytea:
        return p.typeBinary;
      case PgType.array:
      case PgType.unknown:
        return p.text;
    }
  }
}

final _urlPattern = RegExp(r'https?://[^\s<>"\)]+');
final _emailPattern = RegExp(
  r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}',
);
// Phone-number detection. Earlier looser regexes lit up dates
// (`2023.12.22`), serial numbers (`INV-2024-001234567`), and arbitrary
// digit runs. Phones are now matched only when one of these is true:
// - E.164 packed: `+` followed by 8–15 digits.
// - International with separators: `+CC` then 3 more groups separated
// by space or dash (no dots — `2023-12-22` patterns wouldn't match
// anyway since the leading digit group isn't a country code, but we
// also exclude dots so dotted dates can't slip through).
// - Parenthesised area code: `(NNN) NNN-NNNN` style.
// - Strict US dashed/spaced: `NNN[\s\-]NNN[\s\-]NNNN` (3-3-4 only —
// date patterns like `2023-12-22` are 4-2-2 and don't match).
//
// Must also follow start-of-string or a sentence-boundary char so
// identifiers like `INV-2024-...` aren't misread.
//
// Verified:
// ✓ +1 555 123 4567, +44 20 7946 0958, (555) 123-4567,
// 555-123-4567, +15551234567
// ✗ 555.123.4567 (dots disallowed — too easily confused with dates),
// 2023.12.22, 2023-12-22, 12-22-2023, SN12345678,
// INV-2024-001234567
final _phonePattern = RegExp(
  r'(?<=^|[\s,;:()])(?:'
  r'\+\d{8,15}\b'
  r'|'
  r'\+\d{1,3}[\s\-]\d{2,4}[\s\-]\d{2,4}[\s\-]\d{2,4}\b'
  r'|'
  r'\(\d{2,4}\)\s?\d{2,4}[\s\-]?\d{2,4}\b'
  r'|'
  r'\d{3}[\s\-]\d{3}[\s\-]\d{4}\b'
  r')',
);

class _Match {
  final int start;
  final int end;
  final String text;
  final String launchUri;
  const _Match(this.start, this.end, this.text, this.launchUri);
}

bool _isTextLike(PgType t) {
  switch (t) {
    case PgType.text:
    case PgType.varchar:
    case PgType.name:
    case PgType.unknown:
      return true;
    default:
      return false;
  }
}

List<InlineSpan>? _buildSpansWithUrls(
  String text,
  TextStyle baseStyle,
  AppPalette palette,
  bool allowEmailPhone,
) {
  final matches = <_Match>[];
  for (final m in _urlPattern.allMatches(text)) {
    matches.add(_Match(m.start, m.end, m.group(0)!, m.group(0)!));
  }
  if (allowEmailPhone) {
    for (final m in _emailPattern.allMatches(text)) {
      if (_overlaps(matches, m.start, m.end)) continue;
      final raw = m.group(0)!;
      matches.add(_Match(m.start, m.end, raw, 'mailto:$raw'));
    }
    for (final m in _phonePattern.allMatches(text)) {
      if (_overlaps(matches, m.start, m.end)) continue;
      final raw = m.group(0)!;
      final digits = raw.replaceAll(RegExp(r'[^\d\+]'), '');
      if (digits.length < 7) continue;
      matches.add(_Match(m.start, m.end, raw, 'tel:$digits'));
    }
  }
  if (matches.isEmpty) return null;
  matches.sort((a, b) => a.start.compareTo(b.start));

  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final m in matches) {
    if (m.start < cursor) continue;
    if (m.start > cursor) {
      spans.add(
        TextSpan(text: text.substring(cursor, m.start), style: baseStyle),
      );
    }
    spans.add(
      TextSpan(
        text: m.text,
        style: baseStyle.copyWith(
          color: palette.accent,
          decoration: TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()..onTap = () => _open(m.launchUri),
        mouseCursor: SystemMouseCursors.click,
      ),
    );
    cursor = m.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
  }
  return spans;
}

bool _overlaps(List<_Match> matches, int start, int end) {
  for (final m in matches) {
    if (m.start < end && start < m.end) return true;
  }
  return false;
}

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
