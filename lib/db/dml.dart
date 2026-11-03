import 'dart:convert';

import '../catalog/pg_type.dart';
import '../db/executor.dart';
import '../util/sql_quote.dart';
import 'edit_policy.dart';
import 'pg_geometry.dart';
import 'sqlite_kind.dart';

class UpdateResult {
  const UpdateResult({required this.affectedRows, required this.newValue});
  final int affectedRows;
  final Object? newValue;
}

class CellEditor {
  CellEditor(this.conn);
  final DbExecutor conn;

  Future<UpdateResult> updateCell({
    required EditPolicy policy,
    required Map<String, Object?> pkValues,
    required Object? oldValue,
    required Object? newValueRaw,
  }) async {
    final parsed = parseValue(policy, newValueRaw);
    final params = <Object?>[parsed];
    final pkPlaceholders = <String>[];
    for (final primaryKey in policy.pkColumns) {
      params.add(pkValues[primaryKey]);
      pkPlaceholders.add('${quoteIdent(primaryKey)} = \$${params.length}');
    }
    params.add(
      conn.kind == kSqliteKind || !pgGeometricTypes.contains(policy.typeName.toLowerCase())
          ? oldValue
          : pgGeometryText(oldValue),
    );
    final oldPlaceholder = '\$${params.length}';

    final qualified = quoteQualified(policy.schema, policy.table);
    // CURRENT_TIMESTAMP rather than now(): it works on Postgres and SQLite.
    final touches = [
      for (final touchColumn in policy.touchColumns)
        if (touchColumn != policy.column) ', ${quoteIdent(touchColumn)} = CURRENT_TIMESTAMP',
    ].join();
    // SQLite before 3.39 (Android 13 and older phones) has no
    // `IS NOT DISTINCT FROM`; its `IS` is the same NULL-safe comparison and
    // works on every version.
    final guard = conn.kind == kSqliteKind
        ? '${quoteIdent(policy.column)} IS $oldPlaceholder'
        : _postgresGuard(policy, oldPlaceholder);
    final sql =
        'UPDATE $qualified '
        'SET ${quoteIdent(policy.column)} = \$1$touches '
        'WHERE ${pkPlaceholders.join(' AND ')} '
        'AND $guard';

    final result = await conn.execute(sql, positional: params);
    return UpdateResult(affectedRows: result.affectedRows, newValue: parsed);
  }

  /// The optimistic-concurrency guard on Postgres: the column still holds
  /// the value the user saw. `json`, `xml` and the geometric types have no
  /// usable `=` operator, so a plain `IS NOT DISTINCT FROM` fails every edit
  /// of such a column ("operator does not exist: json = unknown").
  /// - json: compared as `jsonb` (key order and whitespace don't count).
  /// - xml: compared as text.
  /// - geometric: the old value is sent as Postgres text ([pgGeometryText]),
  ///   parsed by the server into the column's type and printed back, so
  ///   both sides are the server's own text form of the value.
  static String _postgresGuard(EditPolicy policy, String oldPlaceholder) {
    final column = quoteIdent(policy.column);
    final typeName = policy.typeName.toLowerCase();
    if (pgGeometricTypes.contains(typeName)) {
      return '$column::text IS NOT DISTINCT FROM ($oldPlaceholder::$typeName)::text';
    }
    final cast = switch (typeName) {
      'json' => '::jsonb',
      'xml' => '::text',
      _ => '',
    };
    return '$column$cast IS NOT DISTINCT FROM $oldPlaceholder$cast';
  }

  Future<int> deleteRow({
    required String schema,
    required String table,
    required List<String> pkColumns,
    required Map<String, Object?> pkValues,
  }) async {
    final qualified = quoteQualified(schema, table);
    final params = <Object?>[];
    final wherePlaceholders = <String>[];
    for (final primaryKey in pkColumns) {
      params.add(pkValues[primaryKey]);
      wherePlaceholders.add('${quoteIdent(primaryKey)} = \$${params.length}');
    }
    final sql = 'DELETE FROM $qualified WHERE ${wherePlaceholders.join(' AND ')}';
    final result = await conn.execute(sql, positional: params);
    return result.affectedRows;
  }

  /// Soft-delete by stamping [deletedColumn] with `CURRENT_TIMESTAMP` (not
  /// `now()`, which SQLite lacks). Returns the
  /// number of rows affected — 0 means the row was already soft-deleted
  /// (the `IS NULL` guard skipped it), which we surface to the user as
  /// a "row already gone" toast just like a hard delete.
  Future<int> softDeleteRow({
    required String schema,
    required String table,
    required List<String> pkColumns,
    required Map<String, Object?> pkValues,
    required String deletedColumn,
  }) async {
    final qualified = quoteQualified(schema, table);
    final params = <Object?>[];
    final wherePlaceholders = <String>[];
    for (final primaryKey in pkColumns) {
      params.add(pkValues[primaryKey]);
      wherePlaceholders.add('${quoteIdent(primaryKey)} = \$${params.length}');
    }
    final column = quoteIdent(deletedColumn);
    final sql =
        'UPDATE $qualified SET $column = CURRENT_TIMESTAMP '
        'WHERE ${wherePlaceholders.join(' AND ')} AND $column IS NULL';
    final result = await conn.execute(sql, positional: params);
    return result.affectedRows;
  }

  Future<List<Object?>> insertRow({
    required String schema,
    required String table,
    required List<EditPolicy> editable,
    required Map<String, Object?> values,
    String returning = '*',
  }) async {
    final columns = <String>[];
    final placeholders = <String>[];
    final params = <Object?>[];
    for (final policy in editable) {
      if (!values.containsKey(policy.column)) continue;
      final parsedValue = parseValue(policy, values[policy.column]);
      columns.add(quoteIdent(policy.column));
      params.add(parsedValue);
      placeholders.add('\$${params.length}');
    }
    if (columns.isEmpty) {
      throw const FormatException('Provide at least one column value.');
    }
    final qualified = quoteQualified(schema, table);
    final sql =
        'INSERT INTO $qualified (${columns.join(', ')}) VALUES (${placeholders.join(', ')}) RETURNING $returning';
    final result = await conn.execute(sql, positional: params);
    if (result.isEmpty) return const [];
    return result.first;
  }

  static Object? parseValue(EditPolicy policy, Object? raw) {
    if (raw == null) return null;
    if (raw is String && raw.isEmpty) {
      return policy.nullIfBlank ? null : '';
    }
    final text = raw is String ? raw : raw.toString();
    switch (policy.type) {
      case PgType.int2:
      case PgType.int4:
      case PgType.int8:
        return int.parse(text);
      case PgType.numeric:
      case PgType.real:
      case PgType.doublePrecision:
        return num.parse(text);
      case PgType.bool_:
        if (raw is bool) return raw;
        final lower = text.toLowerCase();
        if (lower == 'true' || lower == 't' || lower == '1') return true;
        if (lower == 'false' || lower == 'f' || lower == '0') return false;
        throw FormatException('Invalid bool: $text');
      case PgType.json:
      case PgType.jsonb:
        final decoded = jsonDecode(text);
        return jsonEncode(decoded);
      case PgType.text:
      case PgType.varchar:
      case PgType.name:
      case PgType.date:
      case PgType.time:
      case PgType.timestamp:
      case PgType.timestamptz:
      case PgType.interval:
      case PgType.uuid:
      case PgType.bytea:
      case PgType.array:
      case PgType.unknown:
        return text;
    }
  }
}
