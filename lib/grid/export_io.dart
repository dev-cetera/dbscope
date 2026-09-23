import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import '../catalog/pg_type.dart';
import '../grid/data_grid.dart';
import '../util/sql_quote.dart';

class ResultExporter {
  static Future<String?> exportSqlText(
    String sql, {
    String suggestedName = 'query.sql',
  }) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SQL', extensions: ['sql']),
      ],
    );
    if (location == null) return null;
    await File(location.path).writeAsString(sql);
    return location.path;
  }

  static Future<String?> exportCsv(GridData data) async {
    final location = await getSaveLocation(
      suggestedName: 'export.csv',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (location == null) return null;
    final buffer = StringBuffer();
    buffer.writeln(data.columns.map((c) => _csvEscape(c.name)).join(','));
    for (final row in data.rows) {
      buffer.writeln(row.map(_csvCell).join(','));
    }
    final file = File(location.path);
    await file.writeAsString(buffer.toString());
    return location.path;
  }

  static Future<String?> exportJson(GridData data) async {
    final location = await getSaveLocation(
      suggestedName: 'export.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) return null;
    final colNames = data.columns.map((c) => c.name).toList();
    final out = <Map<String, Object?>>[];
    for (final row in data.rows) {
      final entry = <String, Object?>{};
      for (var i = 0; i < colNames.length; i++) {
        entry[colNames[i]] = row[i];
      }
      out.add(entry);
    }
    final file = File(location.path);
    await file.writeAsString(const JsonEncoder.withIndent(' ').convert(out));
    return location.path;
  }

  /// Export to a SQLite file. Writes a single table named [tableName]
  /// (defaults to `export`) containing the grid's columns. Existing files
  /// are overwritten so the result is always a clean single-table DB.
  static Future<String?> exportSqlite(
    GridData data, {
    String tableName = 'export',
  }) async {
    final location = await getSaveLocation(
      suggestedName: 'export.db',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SQLite', extensions: ['db', 'sqlite', 'sqlite3']),
      ],
    );
    if (location == null) return null;
    final outFile = File(location.path);
    if (await outFile.exists()) {
      // Overwrite — leaving the previous file behind would silently mix
      // schemas in append mode and surprise users.
      await outFile.delete();
    }
    final db = sq.sqlite3.open(location.path);
    try {
      // Type affinities come from the column's PgType. Anything non-
      // numeric becomes TEXT to avoid lossy coercions; numerics get
      // INTEGER/REAL so casts in downstream tools work.
      final colDefs = <String>[];
      for (final c in data.columns) {
        colDefs.add('${quoteIdent(c.name)} ${_sqliteAffinityFor(c)}');
      }
      final table = quoteIdent(tableName);
      db.execute('CREATE TABLE $table (${colDefs.join(', ')})');
      if (data.rows.isNotEmpty) {
        final cols = data.columns.map((c) => quoteIdent(c.name)).join(', ');
        final placeholders = List.generate(
          data.columns.length,
          (i) => '?',
        ).join(', ');
        final stmt = db.prepare(
          'INSERT INTO $table ($cols) VALUES ($placeholders)',
        );
        try {
          db.execute('BEGIN');
          for (final row in data.rows) {
            stmt.execute([for (final v in row) _toSqliteValue(v)]);
          }
          db.execute('COMMIT');
        } finally {
          stmt.dispose();
        }
      }
    } finally {
      db.dispose();
    }
    return location.path;
  }

  static String _sqliteAffinityFor(GridColumnSpec c) {
    // Match SQLite's type-affinity rules: INTEGER for ints, REAL for
    // floats, BLOB for bytea, TEXT for everything else. This mirrors
    // how SQLite itself classifies declared types.
    switch (c.type) {
      case PgType.int2:
      case PgType.int4:
      case PgType.int8:
        return 'INTEGER';
      case PgType.real:
      case PgType.doublePrecision:
      case PgType.numeric:
        return 'REAL';
      case PgType.bytea:
        return 'BLOB';
      default:
        return 'TEXT';
    }
  }

  static Object? _toSqliteValue(Object? v) {
    if (v == null) return null;
    if (v is String || v is num || v is bool) return v;
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is BigInt) return v.toString();
    if (v is List<int>) return v;
    return v.toString();
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
