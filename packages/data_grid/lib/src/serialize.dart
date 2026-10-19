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
  final originalColumns = <int>[
    for (var viewIndex = range.colMin; viewIndex <= range.colMax; viewIndex++)
      model.viewToOriginal(viewIndex),
  ];
  final lines = <String>[];
  for (var rowIndex = range.rowMin; rowIndex <= range.rowMax; rowIndex++) {
    if (rowIndex < 0 || rowIndex >= data.rows.length) continue;
    final cells = <String>[];
    final row = data.rows[rowIndex];
    for (final originalColumn in originalColumns) {
      if (originalColumn < 0 || originalColumn >= row.length) {
        cells.add('');
        continue;
      }
      cells.add(_tsvEscape(row[originalColumn]));
    }
    lines.add(cells.join('\t'));
  }
  return lines.join('\n');
}

String _tsvEscape(Object? value) {
  if (value == null) return '';
  return value
      .toString()
      .replaceAll(r'\', r'\\')
      .replaceAll('\t', r'\t')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
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
  final originalColumns = <int>[
    for (var viewIndex = range.colMin; viewIndex <= range.colMax; viewIndex++)
      model.viewToOriginal(viewIndex),
  ];
  final lines = <String>[];
  for (var rowIndex = range.rowMin; rowIndex <= range.rowMax; rowIndex++) {
    if (rowIndex < 0 || rowIndex >= data.rows.length) continue;
    final cells = <String>[];
    final row = data.rows[rowIndex];
    for (final originalColumn in originalColumns) {
      if (originalColumn < 0 || originalColumn >= row.length) {
        cells.add('');
        continue;
      }
      cells.add(_csvField(row[originalColumn]));
    }
    lines.add(cells.join(','));
  }
  return lines.join('\r\n');
}

String _csvField(Object? value) {
  if (value == null) return '';
  final text = value.toString();
  final needsQuote =
      text.contains(',') || text.contains('"') || text.contains('\n') || text.contains('\r');
  if (!needsQuote) return text;
  return '"${text.replaceAll('"', '""')}"';
}
