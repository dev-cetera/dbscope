// Web stub of ResultExporter. The web build can't write to a local
// filesystem and doesn't ship the native sqlite3 binary, so this
// implementation copies CSV/JSON to the clipboard instead of saving to
// disk; sqlite export returns null (the UI should hide that menu item
// when running on web, and the export flow already tolerates null).

import 'dart:convert';

import 'package:flutter/services.dart';

import '../grid/data_grid.dart';

class ResultExporter {
  static Future<String?> exportSqlText(
    String sql, {
    String suggestedName = 'query.sql',
  }) async {
    await Clipboard.setData(ClipboardData(text: sql));
    return 'clipboard';
  }

  static Future<String?> exportCsv(GridData data) async {
    final buffer = StringBuffer();
    buffer.writeln(data.columns.map((c) => _csvEscape(c.name)).join(','));
    for (final row in data.rows) {
      buffer.writeln(row.map(_csvCell).join(','));
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    return 'clipboard';
  }

  static Future<String?> exportJson(GridData data) async {
    final colNames = data.columns.map((c) => c.name).toList();
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
    return null;
  }

  static String _csvCell(Object? value) {
    if (value == null) return '';
    final s = value.toString();
    return _csvEscape(s);
  }

  static String _csvEscape(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }
}
