import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:postgres/postgres.dart' as pg;

import '../query/cancel_token.dart';
import 'executor.dart';

/// DbExecutor backed by package:postgres. Owns one TCP connection.
class PostgresExecutor implements DbExecutor {
  PostgresExecutor(pg.Connection conn) : _conn = conn;
  final pg.Connection _conn;

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
  }) async {
    final pg.Result result;
    if (named != null) {
      result = await _conn.execute(pg.Sql.named(sql), parameters: named);
    } else if (positional != null) {
      result = await _conn.execute(pg.Sql(sql), parameters: positional);
    } else {
      result = await _conn.execute(sql);
    }
    if (cancelToken?.isCancelled ?? false) {
      // Caller will translate to a cancel exception; we still return what
      // we have because the query already ran.
    }
    final columns = <DbColumn>[];
    for (var i = 0; i < result.schema.columns.length; i++) {
      final column = result.schema.columns[i];
      columns.add(
        DbColumn(
          name: column.columnName ?? 'col_$i',
          typeName: pgTypeNameForOid(column.type.oid),
        ),
      );
    }
    final rows = <List<Object?>>[
      for (final row in result) [for (final value in row) _decodeValue(value)],
    ];
    return DbResult(
      columns: columns,
      rows: rows,
      affectedRows: result.affectedRows,
    );
  }

  /// `package:postgres` returns [pg.UndecodedBytes] for any OID it doesn't
  /// have a codec for (custom domains, citext, geometric types we don't bind,
  /// etc.). Its `toString()` is the default `Instance of '...'` so it renders
  /// as garbage in the grid.
  ///
  /// Only actual `bytea` (OID 17) gets the `\xDEADBEEF` hex preview — that's
  /// the canonical PG text I/O format, so callers can hand the same string
  /// back as the `oldValue` of an UPDATE and the server will round-trip it.
  /// For everything else (custom domains over text, citext, enums without a
  /// codec, …), the bytes are the UTF-8 representation in both text and
  /// binary protocol modes, so decode them as a string.
  @visibleForTesting
  static Object? decodeValue(Object? value) => _decodeValue(value);

  static const _byteaOid = 17;

  static Object? _decodeValue(Object? value) {
    if (value is! pg.UndecodedBytes) return value;
    if (value.typeOid != _byteaOid) {
      try {
        return value.asString;
      } catch (_) {
        // fall through to hex
      }
    }
    final bytes = value.bytes;
    final buffer = StringBuffer(r'\x');
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

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
  /// [pg.UndecodedBytes] (unknown OID), and [_decodeValue] then hex-encodes
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

/// The Postgres type name (`udt_name` spelling, arrays as `int4[]`) for a
/// built-in type [oid], or null for one this table doesn't know (enums,
/// domains, extension types: their oids differ per database).
/// `pg.Type.toString()` only prints `Type(oid:N)`, which is what query
/// result headers used to show.
String? pgTypeNameForOid(int? oid) => oid == null ? null : _builtinTypeNames[oid];

const _builtinTypeNames = <int, String>{
  16: 'bool',
  17: 'bytea',
  18: 'char',
  19: 'name',
  20: 'int8',
  21: 'int2',
  23: 'int4',
  24: 'regproc',
  25: 'text',
  26: 'oid',
  114: 'json',
  142: 'xml',
  600: 'point',
  650: 'cidr',
  700: 'float4',
  701: 'float8',
  705: 'unknown',
  790: 'money',
  829: 'macaddr',
  869: 'inet',
  1042: 'bpchar',
  1043: 'varchar',
  1082: 'date',
  1083: 'time',
  1114: 'timestamp',
  1184: 'timestamptz',
  1186: 'interval',
  1266: 'timetz',
  1560: 'bit',
  1562: 'varbit',
  1700: 'numeric',
  2205: 'regclass',
  2206: 'regtype',
  2249: 'record',
  2278: 'void',
  2950: 'uuid',
  3614: 'tsvector',
  3802: 'jsonb',
  3904: 'int4range',
  3906: 'numrange',
  3908: 'tsrange',
  3910: 'tstzrange',
  3912: 'daterange',
  3926: 'int8range',
  4089: 'regnamespace',
  // Arrays.
  199: 'json[]',
  651: 'cidr[]',
  1000: 'bool[]',
  1001: 'bytea[]',
  1003: 'name[]',
  1005: 'int2[]',
  1007: 'int4[]',
  1009: 'text[]',
  1014: 'bpchar[]',
  1015: 'varchar[]',
  1016: 'int8[]',
  1021: 'float4[]',
  1022: 'float8[]',
  1041: 'inet[]',
  1115: 'timestamp[]',
  1182: 'date[]',
  1183: 'time[]',
  1185: 'timestamptz[]',
  1187: 'interval[]',
  1231: 'numeric[]',
  2951: 'uuid[]',
  3807: 'jsonb[]',
};
