// Text formatting for metadata `display.renderer` values. Pure, so it is
// unit-testable; the widget side (CellValueDisplay) only decides where the
// text goes and adds a swatch for colours.
//
// rendererArgs per renderer:
//   money      { currency: "AUD", minorUnits: true, decimals: 2 }
//   bytes      { }                        → 1.4 MB
//   duration   { unit: "ms" | "s" | "min" }  → 2m 05s
//   timestamp  { utcOffset: "+10:00" | local: true, format: "date" }
//   relativeTime { }                      → 3 h ago
//
// Time zones: Dart has no IANA zone database without an extra package, so
// a fixed `utcOffset` (or `local: true` for the viewer's machine zone) is
// what is supported. Zones without daylight saving (e.g. Brisbane, +10:00)
// are exact; DST zones are off by an hour half the year — say so in the
// metadata note if it matters.

import 'masked_value.dart';
import 'meta_models.dart';

/// Formatted text for [value], or null to fall back to the default display.
String? formatForRenderer(
  ValueRenderer renderer,
  Map<String, Object?> args,
  Object? value, {
  DateTime? now,
}) {
  if (value == null || value is MaskedValue) return null;
  switch (renderer) {
    case ValueRenderer.money:
      return _money(args, value);
    case ValueRenderer.bytes:
      final n = _number(value);
      return n == null ? null : formatBytes(n);
    case ValueRenderer.duration:
      final n = _number(value);
      if (n == null) return null;
      final unit = specString(args, 'unit') ?? 'ms';
      final ms = switch (unit) {
        's' => n * 1000,
        'min' => n * 60000,
        _ => n,
      };
      return formatDuration(Duration(milliseconds: ms.round()));
    case ValueRenderer.timestamp:
      final t = _dateTime(value);
      if (t == null) return null;
      return formatTimestamp(t, args);
    case ValueRenderer.relativeTime:
      final t = _dateTime(value);
      if (t == null) return null;
      return formatRelative(t, now ?? DateTime.now());
    case ValueRenderer.imageUrl:
    case ValueRenderer.url:
    case ValueRenderer.color:
    case ValueRenderer.markdown:
    case ValueRenderer.json:
      return null;
  }
}

/// A finite number, or null (NaN/Infinity must never reach a formatter:
/// `.round()` and `toStringAsFixed` throw on them).
num? _number(Object value) {
  final n = value is num ? value : num.tryParse(value.toString());
  if (n == null || !n.isFinite) return null;
  return n;
}

/// Parses a timestamp. A string with no zone ("2024-01-01 10:00:00", the
/// usual SQLite shape) is taken as UTC — the convention for stored
/// timestamps — rather than the viewer's local time.
DateTime? _dateTime(Object value) {
  if (value is DateTime) return value;
  final text = value.toString().trim();
  final hasZone = RegExp(r'(Z|[+-]\d{2}(:?\d{2})?)$').hasMatch(text);
  final looksTimed = RegExp(r'\d{2}:\d{2}').hasMatch(text);
  return DateTime.tryParse(hasZone || !looksTimed ? text : '${text}Z');
}

String? _money(Map<String, Object?> args, Object value) {
  final n = _number(value);
  if (n == null) return null;
  final minor = specBool(args, 'minorUnits');
  final decimals = (specInt(args, 'decimals') ?? 2).clamp(0, 20);
  final amount = minor ? n / 100 : n;
  final currency = specString(args, 'currency');
  final fixed = amount.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final grouped = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  final body = parts.length > 1 ? '$grouped.${parts[1]}' : grouped;
  final sign = amount < 0 ? '-' : '';
  return currency == null ? '$sign$body' : '$sign$body $currency';
}

String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value.abs() >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

String formatDuration(Duration d) {
  final negative = d.isNegative;
  final abs = d.abs();
  String core;
  if (abs.inMilliseconds < 1000) {
    core = '${abs.inMilliseconds} ms';
  } else if (abs.inSeconds < 60) {
    final seconds = abs.inMilliseconds / 1000;
    core = '${seconds.toStringAsFixed(seconds < 10 ? 2 : 1)} s';
  } else if (abs.inMinutes < 60) {
    final seconds = (abs.inSeconds % 60).toString().padLeft(2, '0');
    core = '${abs.inMinutes}m ${seconds}s';
  } else {
    final minutes = (abs.inMinutes % 60).toString().padLeft(2, '0');
    core = '${abs.inHours}h ${minutes}m';
  }
  return negative ? '-$core' : core;
}

String formatTimestamp(DateTime t, Map<String, Object?> args) {
  DateTime shown;
  String suffix;
  final offset = _parseOffset(specString(args, 'utcOffset'));
  if (offset != null) {
    shown = t.toUtc().add(offset);
    suffix = ' ${specString(args, 'utcOffset')}';
  } else if (specBool(args, 'local')) {
    shown = t.toLocal();
    suffix = '';
  } else {
    shown = t.toUtc();
    suffix = ' UTC';
  }
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${shown.year}-${two(shown.month)}-${two(shown.day)}';
  if (specString(args, 'format') == 'date') return date;
  return '$date ${two(shown.hour)}:${two(shown.minute)}:${two(shown.second)}$suffix';
}

Duration? _parseOffset(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'^([+-])(\d{1,2}):?(\d{2})?$').firstMatch(raw.trim());
  if (m == null) return null;
  final sign = m.group(1) == '-' ? -1 : 1;
  final hours = int.parse(m.group(2)!);
  final minutes = int.parse(m.group(3) ?? '0');
  return Duration(minutes: sign * (hours * 60 + minutes));
}

String formatRelative(DateTime t, DateTime now) {
  final diff = now.difference(t);
  final future = diff.isNegative;
  final d = diff.abs();
  String core;
  if (d.inSeconds < 60) {
    core = '${d.inSeconds} s';
  } else if (d.inMinutes < 60) {
    core = '${d.inMinutes} min';
  } else if (d.inHours < 48) {
    core = '${d.inHours} h';
  } else if (d.inDays < 60) {
    core = '${d.inDays} d';
  } else if (d.inDays < 730) {
    core = '${(d.inDays / 30).floor()} mo';
  } else {
    core = '${(d.inDays / 365).floor()} y';
  }
  return future ? 'in $core' : '$core ago';
}

/// `#rgb` / `#rrggbb` / `#rrggbbaa` (CSS order) → ARGB int, for the
/// colour swatch. Anything else (including a sign) is not a colour.
int? parseColorValue(Object? value) {
  if (value == null || value is MaskedValue) return null;
  var text = value.toString().trim();
  if (text.startsWith('#')) text = text.substring(1);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) return null;
  if (text.length == 3) {
    text = text.split('').map((c) => '$c$c').join();
  }
  if (text.length == 6) return 0xFF000000 | int.parse(text, radix: 16);
  if (text.length == 8) {
    // CSS puts alpha last; Flutter's Color wants it first.
    final rgb = int.parse(text.substring(0, 6), radix: 16);
    final alpha = int.parse(text.substring(6), radix: 16);
    return (alpha << 24) | rgb;
  }
  return null;
}

/// Renders a `{col}` row-label template against a row. Masked or missing
/// columns render as the mask or as an empty string.
String renderRowLabel(String template, Map<String, Object?> row) {
  return template.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (m) {
    final value = row[m.group(1)!];
    return value?.toString() ?? '';
  }).trim();
}
