import 'dart:convert';

import 'export_names.dart';

/// The JSON export of a result set: an array with one object per row.
///
/// Values the Postgres driver hands back that `jsonEncode` can't take on
/// its own (a `DateTime` for every date and timestamp column, `BigInt`,
/// intervals, geometric types) are written as text, so exporting any
/// result with a timestamp column doesn't fail. Repeated column names
/// (`SELECT a.id, b.id …`) get suffixes, so no column overwrites another.
String encodeRowsAsJson(List<String> columnNames, List<List<Object?>> rows) {
  final keys = uniqueColumnNames(columnNames);
  final out = [
    for (final row in rows)
      {for (var i = 0; i < keys.length; i++) keys[i]: i < row.length ? row[i] : null},
  ];
  return const JsonEncoder.withIndent(' ', _toEncodable).convert(out);
}

Object? _toEncodable(Object? value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  return value.toString();
}
