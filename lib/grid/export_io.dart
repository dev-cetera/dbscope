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
    buffer.writeln(
      data.columns.map((column) => _csvEscape(column.name)).join(','),
    );
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
    final colNames = data.columns.map((column) => column.name).toList();
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
    if (outFile.existsSync()) {
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
      for (final column in data.columns) {
        colDefs.add('${quoteIdent(column.name)} ${_sqliteAffinityFor(column)}');
      }
      final table = quoteIdent(tableName);
      db.execute('CREATE TABLE $table (${colDefs.join(', ')})');
      if (data.rows.isNotEmpty) {
        final columns = data.columns.map((column) => quoteIdent(column.name)).join(', ');
        final placeholders = List.generate(
          data.columns.length,
          (i) => '?',
        ).join(', ');
        final statement = db.prepare(
          'INSERT INTO $table ($columns) VALUES ($placeholders)',
        );
        try {
          db.execute('BEGIN');
          for (final row in data.rows) {
            statement.execute([for (final value in row) _toSqliteValue(value)]);
          }
          db.execute('COMMIT');
        } finally {
          statement.dispose();
        }
      }
    } finally {
      db.dispose();
    }
    return location.path;
  }

  static String _sqliteAffinityFor(GridColumnSpec column) {
    // Match SQLite's type-affinity rules: INTEGER for ints, REAL for
    // floats, BLOB for bytea, TEXT for everything else. This mirrors
    // how SQLite itself classifies declared types.
    switch (column.type) {
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
      case PgType.text:
      case PgType.varchar:
      case PgType.name:
      case PgType.bool_:
      case PgType.date:
      case PgType.time:
      case PgType.timestamp:
      case PgType.timestamptz:
      case PgType.interval:
      case PgType.uuid:
      case PgType.json:
      case PgType.jsonb:
      case PgType.array:
      case PgType.unknown:
      case null:
        return 'TEXT';
    }
  }

  static Object? _toSqliteValue(Object? value) {
    if (value == null) return null;
    if (value is String || value is num || value is bool) return value;
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is BigInt) return value.toString();
    if (value is List<int>) return value;
    return value.toString();
  }

  static String _csvCell(Object? value) {
    if (value == null) return '';
    final text = value.toString();
    return _csvEscape(text);
  }

  static String _csvEscape(String text) {
    if (text.contains(',') || text.contains('"') || text.contains('\n')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }
}
