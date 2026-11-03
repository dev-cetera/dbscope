// Web stub of ResultExporter. The web build can't write to a local
// filesystem and doesn't ship the native sqlite3 binary, so this
// implementation copies CSV/JSON to the clipboard instead of saving to
// disk. There is no sqlite export: [ResultExporter.supportsSqliteExport] is
// false and the UI hides the `.db` button.

import 'dart:convert';

import 'package:flutter/services.dart';

import '../grid/data_grid.dart';

class ResultExporter {
  /// Whether [exportSqlite] can write a file on this platform.
  static const supportsSqliteExport = false;

  static Future<String?> exportSqlText(
    String sql, {
    String suggestedName = 'query.sql',
  }) async {
    await Clipboard.setData(ClipboardData(text: sql));
    return 'clipboard';
  }

  static Future<String?> exportCsv(GridData data) async {
    final buffer = StringBuffer();
    buffer.writeln(
      data.columns.map((column) => _csvEscape(column.name)).join(','),
    );
    for (final row in data.rows) {
      buffer.writeln(row.map(_csvCell).join(','));
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    return 'clipboard';
  }

  static Future<String?> exportJson(GridData data) async {
    final colNames = data.columns.map((column) => column.name).toList();
    final out = <Map<String, Object?>>[];
    for (final row in data.rows) {
      final entry = <String, Object?>{};
      for (var i = 0; i < colNames.length; i++) {
        entry[colNames[i]] = row[i];
      }
      out.add(entry);
    }
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent(' ').convert(out),
      ),
    );
    return 'clipboard';
  }

  static Future<String?> exportSqlite(
    GridData data, {
    String tableName = 'export',
  }) async {
    throw UnsupportedError('.db export is not available in the web build');
  }

  static String _csvCell(Object? value) {
    if (value == null) return '';
    final text = value.toString();
    return _csvEscape(text);
  }

  static String _csvEscape(String text) {
    // A bare `\r` ends a record for RFC 4180 readers just like `\n` does.
    if (text.contains(',') ||
        text.contains('"') ||
        text.contains('\n') ||
        text.contains('\r')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }
}
