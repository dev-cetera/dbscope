import 'dart:convert';

import '../catalog/pg_type.dart';
import '../db/executor.dart';
import '../util/sql_quote.dart';
import 'edit_policy.dart';

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
    for (final pk in policy.pkColumns) {
      params.add(pkValues[pk]);
      pkPlaceholders.add('${quoteIdent(pk)} = \$${params.length}');
    }
    params.add(oldValue);
    final oldPlaceholder = '\$${params.length}';

    final qualified = quoteQualified(policy.schema, policy.table);
    // CURRENT_TIMESTAMP rather than now(): it works on Postgres and SQLite.
    final touches = [
      for (final c in policy.touchColumns)
        if (c != policy.column) ', ${quoteIdent(c)} = CURRENT_TIMESTAMP',
    ].join();
    final sql =
        'UPDATE $qualified '
        'SET ${quoteIdent(policy.column)} = \$1$touches '
        'WHERE ${pkPlaceholders.join(' AND ')} '
        'AND ${quoteIdent(policy.column)} IS NOT DISTINCT FROM $oldPlaceholder';

    final result = await conn.execute(sql, positional: params);
    return UpdateResult(affectedRows: result.affectedRows, newValue: parsed);
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
    for (final pk in pkColumns) {
      params.add(pkValues[pk]);
      wherePlaceholders.add('${quoteIdent(pk)} = \$${params.length}');
    }
    final sql =
        'DELETE FROM $qualified WHERE ${wherePlaceholders.join(' AND ')}';
    final result = await conn.execute(sql, positional: params);
    return result.affectedRows;
  }

  /// Soft-delete by stamping [deletedColumn] with `now()`. Returns the
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
    for (final pk in pkColumns) {
      params.add(pkValues[pk]);
      wherePlaceholders.add('${quoteIdent(pk)} = \$${params.length}');
    }
    final col = quoteIdent(deletedColumn);
    final sql =
        'UPDATE $qualified SET $col = now() '
        'WHERE ${wherePlaceholders.join(' AND ')} AND $col IS NULL';
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
    final cols = <String>[];
    final placeholders = <String>[];
    final params = <Object?>[];
    for (final p in editable) {
      if (!values.containsKey(p.column)) continue;
      final v = parseValue(p, values[p.column]);
      cols.add(quoteIdent(p.column));
      params.add(v);
      placeholders.add('\$${params.length}');
    }
    if (cols.isEmpty) {
      throw const FormatException('Provide at least one column value.');
    }
    final qualified = quoteQualified(schema, table);
    final sql =
        'INSERT INTO $qualified (${cols.join(', ')}) VALUES (${placeholders.join(', ')}) RETURNING $returning';
    final result = await conn.execute(sql, positional: params);
    if (result.isEmpty) return const [];
    return result.first;
  }

  static Object? parseValue(EditPolicy policy, Object? raw) {
    if (raw == null) return null;
    if (raw is String && raw.isEmpty) {
      return policy.nullIfBlank ? null : '';
    }
    final s = raw is String ? raw : raw.toString();
    switch (policy.type) {
      case PgType.int2:
      case PgType.int4:
      case PgType.int8:
        return int.parse(s);
      case PgType.numeric:
      case PgType.real:
      case PgType.doublePrecision:
        return num.parse(s);
      case PgType.bool_:
        if (raw is bool) return raw;
        final lower = s.toLowerCase();
        if (lower == 'true' || lower == 't' || lower == '1') return true;
        if (lower == 'false' || lower == 'f' || lower == '0') return false;
        throw FormatException('Invalid bool: $s');
      case PgType.json:
      case PgType.jsonb:
        final decoded = jsonDecode(s);
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
        return s;
    }
  }
}
