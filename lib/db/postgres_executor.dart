import 'dart:typed_data';

import 'package:dbscope_pg_core/dbscope_pg_core.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:postgres/postgres.dart' as pg;

import '../query/cancel_token.dart';
import 'executor.dart';

export 'package:dbscope_pg_core/dbscope_pg_core.dart' show pgTypeNameForOid;

/// DbExecutor backed by package:postgres. Owns one TCP connection.
class PostgresExecutor implements DbExecutor {
  PostgresExecutor(pg.Connection conn) : _conn = conn, _session = PgSession(conn);
  final pg.Connection _conn;
  final PgSession _session;

  /// The underlying connection. Some legacy paths (e.g. server-side jobs
  /// that drop down to raw protocol features) still need direct access.
  /// Anything that doesn't require pg-specific behaviour should use the
  /// DbExecutor surface instead.
  pg.Connection get raw => _conn;

  @override
  String get kind => 'postgres';

  @override
  bool get isOpen => _conn.isOpen;

  @override
  DbCapabilities get capabilities => DbCapabilities.postgres;

  @override
  Future<DbResult> execute(
    String sql, {
    List<Object?>? positional,
    Map<String, Object?>? named,
    CancelToken? cancelToken,
    RowCap? rowCap,
  }) async {
    if (cancelToken?.isCancelled ?? false) return const DbResult(columns: [], rows: []);
    final run = await _session.run(
      sql,
      positional: positional,
      named: named,
      rowCap: rowCap,
      cancelRequested: cancelToken?.whenCancelled,
    );
    if (run.cancelled) return const DbResult(columns: [], rows: []);
    final schemaColumns = run.schema?.columns ?? const <pg.ResultSchemaColumn>[];
    await _learnTypeNames([for (final c in schemaColumns) c.type.oid]);
    final columns = <DbColumn>[];
    for (var i = 0; i < schemaColumns.length; i++) {
      final column = schemaColumns[i];
      final oid = column.type.oid;
      columns.add(
        DbColumn(
          name: column.columnName ?? 'col_$i',
          typeName: pgTypeNameForOid(oid) ?? _customTypeNames[oid],
        ),
      );
    }
    final isArrayColumn = [
      for (final column in columns) PgValueText.isArrayTypeName(column.typeName),
    ];
    final rows = <List<Object?>>[
      for (final row in run.rows)
        [
          for (var i = 0; i < row.length; i++) PgValueText.decode(row[i], isArray: isArrayColumn[i]),
        ],
    ];
    return DbResult(
      columns: columns,
      rows: rows,
      affectedRows: run.affectedRows,
      truncated: run.truncated,
    );
  }

  /// Names of this database's own types (enums, domains, extension types)
  /// by oid, learned on first sight: their oids differ per database, so
  /// they can't be in the built-in table. A null value means the lookup
  /// found nothing, so it isn't asked again.
  final Map<int, String?> _customTypeNames = {};

  Future<void> _learnTypeNames(List<int?> oids) async {
    final unknown = {
      for (final oid in oids)
        if (oid != null &&
            pgTypeNameForOid(oid) == null &&
            !_customTypeNames.containsKey(oid))
          oid,
    };
    if (unknown.isEmpty) return;
    for (final oid in unknown) {
      _customTypeNames[oid] = null;
    }
    try {
      final rows = await _conn.execute(
        pg.Sql.named(
          'SELECT oid::int8, typname::text FROM pg_type WHERE oid::int8 = ANY(@oids)',
        ),
        parameters: {
          'oids': pg.TypedValue(pg.Type.bigIntegerArray, unknown.toList()),
        },
      );
      for (final row in rows) {
        _customTypeNames[(row[0]! as num).toInt()] = row[1] as String?;
      }
    } catch (_) {
      // A header without a type name is all this costs.
    }
  }

  /// See [PgValueText.decode].
  @visibleForTesting
  static Object? decodeValue(Object? value, {bool isArray = false}) =>
      PgValueText.decode(value, isArray: isArray);

  @override
  Future<void> setReadOnly({required bool readOnly}) async {
    await _conn.execute(
      'SET default_transaction_read_only = ${readOnly ? 'ON' : 'OFF'}',
    );
  }

  @override
  Future<void> close({bool force = false}) async {
    if (!_conn.isOpen) return;
    try {
      await _conn.close(force: force);
    } catch (_) {}
  }

  /// Queries `pg_type` for every user-defined enum type and returns a map of
  /// `oid -> codec` ready to feed into `pg.TypeRegistry(codecs: ...)`.
  ///
  /// Without this, `package:postgres` returns enum values as
  /// [pg.UndecodedBytes] (unknown OID), and [PgValueText.decode] then hex-encodes
  /// them as `\x50415353574f5244` instead of the label `'PASSWORD'`.
  static Future<Map<int, pg.Codec>> loadEnumCodecs(pg.Connection conn) async {
    final result = await conn.execute(
      "SELECT oid FROM pg_type WHERE typtype = 'e'",
    );
    final out = <int, pg.Codec>{};
    for (final row in result) {
      final oid = row[0];
      if (oid is int) out[oid] = _EnumCodec();
    }
    return out;
  }
}

/// Codec for user-defined enum types. The on-wire representation in both
/// text and binary formats is just the UTF-8 bytes of the label, so a single
/// codec covers both directions without branching on `isBinary`.
class _EnumCodec extends pg.Codec {
  _EnumCodec();

  @override
  pg.EncodedValue? encode(pg.TypedValue input, pg.CodecContext context) {
    final value = input.value;
    if (value == null) return null;
    final bytes = Uint8List.fromList(
      context.encoding.encode(value.toString()),
    );
    return pg.EncodedValue.text(bytes);
  }

  @override
  Object? decode(pg.EncodedValue input, pg.CodecContext context) {
    final bytes = input.bytes;
    if (bytes == null) return null;
    return context.encoding.decode(bytes);
  }
}
