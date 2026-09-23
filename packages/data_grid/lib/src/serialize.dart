import 'cell_range.dart';
import 'grid_data.dart';
import 'grid_model.dart';

/// Read rows out of [data] in selection order and serialise as TSV.
/// Used by Cmd+C. Newlines and tabs inside cells are escaped with
/// `\n` / `\t` so a single TSV cell never spans rows.
String serializeRangeAsTsv<T>(
  GridData<T> data,
  GridModel model,
  CellRange range,
) {
  final originalCols = <int>[
    for (var v = range.colMin; v <= range.colMax; v++) model.viewToOriginal(v),
  ];
  final lines = <String>[];
  for (var r = range.rowMin; r <= range.rowMax; r++) {
    if (r < 0 || r >= data.rows.length) continue;
    final cells = <String>[];
    final row = data.rows[r];
    for (final c in originalCols) {
      if (c < 0 || c >= row.length) {
        cells.add('');
        continue;
      }
      cells.add(_tsvEscape(row[c]));
    }
    lines.add(cells.join('\t'));
  }
  return lines.join('\n');
}

String _tsvEscape(Object? value) {
  if (value == null) return '';
  return value
      .toString()
      .replaceAll('\\', '\\\\')
      .replaceAll('\t', '\\t')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r');
}

/// RFC 4180 CSV serialisation of the selected range. Fields
/// containing commas, double-quotes, CR or LF are wrapped in double
/// quotes; embedded quotes are doubled. Lines join with CRLF as the
/// spec requires.
String serializeRangeAsCsv<T>(
  GridData<T> data,
  GridModel model,
  CellRange range,
) {
  final originalCols = <int>[
    for (var v = range.colMin; v <= range.colMax; v++) model.viewToOriginal(v),
  ];
  final lines = <String>[];
  for (var r = range.rowMin; r <= range.rowMax; r++) {
    if (r < 0 || r >= data.rows.length) continue;
    final cells = <String>[];
    final row = data.rows[r];
    for (final c in originalCols) {
      if (c < 0 || c >= row.length) {
        cells.add('');
        continue;
      }
      cells.add(_csvField(row[c]));
    }
    lines.add(cells.join(','));
  }
  return lines.join('\r\n');
}

String _csvField(Object? value) {
  if (value == null) return '';
  final s = value.toString();
  final needsQuote = s.contains(',') ||
      s.contains('"') ||
      s.contains('\n') ||
      s.contains('\r');
  if (!needsQuote) return s;
  return '"${s.replaceAll('"', '""')}"';
}
