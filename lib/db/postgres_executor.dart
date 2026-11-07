import 'dart:convert';
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
    final schemaColumns = result.schema.columns;
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
      for (final column in columns) _isArrayTypeName(column.typeName),
    ];
    final rows = <List<Object?>>[
      for (final row in result)
        [
          for (var i = 0; i < row.length; i++) _decodeValue(row[i], isArray: isArrayColumn[i]),
        ],
    ];
    return DbResult(
      columns: columns,
      rows: rows,
      affectedRows: result.affectedRows,
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

  /// Turns what `package:postgres` hands back into the value the grid, the
  /// editor and the optimistic-concurrency guard all use. Types the driver
  /// decodes to a Dart object that has no Postgres-text form (`Interval`,
  /// `Time`, `Uint8List`, arrays) and types it can't decode at all
  /// ([pg.UndecodedBytes]) become the text Postgres itself prints and
  /// accepts, so an edit can send the old value back and the server parses
  /// it into the column's type.
  ///
  /// [isArray] says the column is an array type. It has to come from the
  /// column, not the value: `json`/`jsonb` values are Lists too.
  @visibleForTesting
  static Object? decodeValue(Object? value, {bool isArray = false}) =>
      _decodeValue(value, isArray: isArray);

  static const _byteaOid = 17;
  static const _moneyOid = 790;
  static const _macaddrOid = 829;
  static const _macaddr8Oid = 774;
  static const _inetOid = 869;
  static const _cidrOid = 650;
  static const _timetzOid = 1266;
  static const _bitOid = 1560;
  static const _varbitOid = 1562;

  static bool _isArrayTypeName(String? typeName) =>
      typeName != null && (typeName.endsWith('[]') || typeName.startsWith('_'));

  static Object? _decodeValue(Object? value, {required bool isArray}) {
    if (value is pg.UndecodedBytes) return _decodeUndecoded(value);
    if (value is pg.Interval) return _intervalText(value);
    if (value is pg.Time) return _clockText(value.microseconds);
    if (value is Uint8List) return _hexText(value);
    if (isArray && value is List) return _arrayText(value);
    return value;
  }

  /// The driver has no codec for these, so they arrive as raw bytes. In
  /// text format the bytes are the text. In binary format only the
  /// text-like types (citext, domains over text, enums, ...) are UTF-8;
  /// the fixed-layout types below are decoded from their binary layout.
  static Object? _decodeUndecoded(pg.UndecodedBytes value) {
    final bytes = value.bytes;
    if (value.isBinary) {
      switch (value.typeOid) {
        case _byteaOid:
          return _hexText(bytes);
        case _moneyOid:
          return _moneyText(bytes);
        case _inetOid:
          return _inetText(bytes, isCidrType: false);
        case _cidrOid:
          return _inetText(bytes, isCidrType: true);
        case _macaddrOid:
        case _macaddr8Oid:
          return _macText(bytes);
        case _timetzOid:
          return _timetzText(bytes);
        case _bitOid:
        case _varbitOid:
          return _bitText(bytes);
      }
    } else if (value.typeOid == _byteaOid) {
      return _hexText(bytes);
    }
    try {
      return value.asString;
    } catch (_) {
      return _hexText(bytes);
    }
  }

  static String _hexText(Uint8List bytes) {
    final buffer = StringBuffer(r'\x');
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _plural(int count, String unit) => '$count $unit${count.abs() == 1 ? '' : 's'}';

  /// Postgres's own interval output: `1 year 2 mons 3 days 04:05:06.5`.
  static String _intervalText(pg.Interval interval) {
    final parts = <String>[];
    final years = interval.months ~/ 12;
    final months = interval.months.remainder(12);
    if (years != 0) parts.add(_plural(years, 'year'));
    if (months != 0) parts.add(_plural(months, 'mon'));
    if (interval.days != 0) parts.add(_plural(interval.days, 'day'));
    if (interval.microseconds != 0 || parts.isEmpty) {
      final clock = _clockText(interval.microseconds.abs());
      parts.add(interval.microseconds < 0 ? '-$clock' : clock);
    }
    return parts.join(' ');
  }

  static const _microsPerSecond = 1000000;
  static const int _microsPerMinute = 60 * _microsPerSecond;
  static const int _microsPerHour = 60 * _microsPerMinute;

  /// `HH:MM:SS[.ffffff]` for a non-negative microsecond count (hours may
  /// exceed 24 for an interval).
  static String _clockText(int microseconds) {
    final hours = microseconds ~/ _microsPerHour;
    final minutes = microseconds % _microsPerHour ~/ _microsPerMinute;
    final seconds = microseconds % _microsPerMinute ~/ _microsPerSecond;
    final fraction = microseconds % _microsPerSecond;
    final base =
        '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
    if (fraction == 0) return base;
    return '$base.${fraction.toString().padLeft(6, '0').replaceFirst(RegExp(r'0+$'), '')}';
  }

  static int _int64(Uint8List bytes, [int offset = 0]) =>
      ByteData.sublistView(bytes).getInt64(offset);

  static int _int32(Uint8List bytes, [int offset = 0]) =>
      ByteData.sublistView(bytes).getInt32(offset);

  /// Binary `money` is a count of the smallest currency unit. Assumes two
  /// fractional digits (the `lc_monetary` of en_US); the symbol and
  /// grouping are dropped, so the text is plain and re-parseable.
  static String _moneyText(Uint8List bytes) {
    final cents = _int64(bytes);
    final absolute = cents.abs();
    final text = '${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
    return cents < 0 ? '-$text' : text;
  }

  static const _ipv4Family = 2;
  static const _ipv4Bits = 32;
  static const _ipv6Bits = 128;

  /// Binary `inet`/`cidr`: family, prefix bits, is-cidr flag, byte count,
  /// address. `inet` prints the prefix only when it is not the full width;
  /// `cidr` always does.
  static String _inetText(Uint8List bytes, {required bool isCidrType}) {
    final isV4 = bytes[0] == _ipv4Family;
    final bits = bytes[1];
    final addressBytes = bytes.sublist(4, 4 + bytes[3]);
    final address = isV4 ? addressBytes.join('.') : _ipv6Text(addressBytes);
    final fullWidth = isV4 ? _ipv4Bits : _ipv6Bits;
    return isCidrType || bits != fullWidth ? '$address/$bits' : address;
  }

  /// RFC 5952 text: lower-case hex, the longest run of zero groups
  /// (length 2 or more) collapsed to `::`.
  static String _ipv6Text(Uint8List bytes) {
    final groups = [for (var i = 0; i < 16; i += 2) bytes[i] << 8 | bytes[i + 1]];
    var bestStart = -1;
    var bestLength = 0;
    var runStart = -1;
    for (var i = 0; i <= groups.length; i++) {
      if (i < groups.length && groups[i] == 0) {
        if (runStart < 0) runStart = i;
        continue;
      }
      if (runStart >= 0 && i - runStart > bestLength) {
        bestStart = runStart;
        bestLength = i - runStart;
      }
      runStart = -1;
    }
    String join(List<int> part) => part.map((group) => group.toRadixString(16)).join(':');
    if (bestLength < 2) return join(groups);
    return '${join(groups.sublist(0, bestStart))}::${join(groups.sublist(bestStart + bestLength))}';
  }

  static String _macText(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(':');

  /// Binary `timetz`: microseconds since midnight, then the zone in seconds
  /// WEST of UTC (so `+02` is stored as -7200).
  static String _timetzText(Uint8List bytes) {
    final clock = _clockText(_int64(bytes));
    final offsetSeconds = -_int32(bytes, 8);
    final sign = offsetSeconds < 0 ? '-' : '+';
    final absolute = offsetSeconds.abs();
    final hours = (absolute ~/ 3600).toString().padLeft(2, '0');
    final minutes = absolute % 3600 ~/ 60;
    final seconds = absolute % 60;
    final buffer = StringBuffer('$clock$sign$hours');
    if (minutes != 0 || seconds != 0) buffer.write(':${minutes.toString().padLeft(2, '0')}');
    if (seconds != 0) buffer.write(':${seconds.toString().padLeft(2, '0')}');
    return buffer.toString();
  }

  /// Binary `bit`/`varbit`: bit count, then the bits packed MSB first.
  static String _bitText(Uint8List bytes) {
    final bitCount = _int32(bytes);
    final buffer = StringBuffer();
    for (var i = 0; i < bitCount; i++) {
      buffer.write((bytes[4 + i ~/ 8] >> (7 - i % 8)) & 1);
    }
    return buffer.toString();
  }

  /// A Postgres array literal (`{1,2}`, `{"a b",NULL}`). Elements that
  /// aren't numbers or booleans are double-quoted, so commas, braces and
  /// whitespace in a value can't change the array's shape.
  static String _arrayText(List<Object?> list) =>
      '{${list.map(_arrayElementText).join(',')}}';

  static String _arrayElementText(Object? element) {
    if (element == null) return 'NULL';
    if (element is List) return _arrayText(element);
    if (element is bool || (element is num && element.isFinite)) return '$element';
    final text = switch (element) {
      pg.Interval() => _intervalText(element),
      pg.Time() => _clockText(element.microseconds),
      Uint8List() => _hexText(element),
      DateTime() => element.toIso8601String(),
      Map() => jsonEncode(element),
      _ => '$element',
    };
    return '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
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
/// domains, extension types: their oids differ per database, so
/// [PostgresExecutor] looks those up in `pg_type` once per connection).
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
