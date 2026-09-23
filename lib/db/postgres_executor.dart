import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:postgres/postgres.dart' as pg;

import '../query/cancel_token.dart';
import 'executor.dart';

/// DbExecutor backed by package:postgres. Owns one TCP connection.
class PostgresExecutor implements DbExecutor {
  final pg.Connection _conn;

  PostgresExecutor(this._conn);

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
    final cols = <DbColumn>[];
    for (var i = 0; i < result.schema.columns.length; i++) {
      final c = result.schema.columns[i];
      cols.add(
        DbColumn(
          name: c.columnName ?? 'col_$i',
          typeName: c.type.toString().split('.').last,
        ),
      );
    }
    final rows = <List<Object?>>[
      for (final r in result) [for (final v in r) _decodeValue(v)],
    ];
    return DbResult(
      columns: cols,
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
  static Object? decodeValue(Object? v) => _decodeValue(v);

  static const int _byteaOid = 17;

  static Object? _decodeValue(Object? v) {
    if (v is! pg.UndecodedBytes) return v;
    if (v.typeOid != _byteaOid) {
      try {
        return v.asString;
      } catch (_) {
        // fall through to hex
      }
    }
    final b = v.bytes;
    final sb = StringBuffer(r'\x');
    for (final byte in b) {
      sb.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  @override
  Future<void> setReadOnly(bool readOnly) async {
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
    final v = input.value;
    if (v == null) return null;
    final bytes = Uint8List.fromList(context.encoding.encode(v.toString()));
    return pg.EncodedValue.text(bytes);
  }

  @override
  Object? decode(pg.EncodedValue input, pg.CodecContext context) {
    final bytes = input.bytes;
    if (bytes == null) return null;
    return context.encoding.decode(bytes);
  }
}
