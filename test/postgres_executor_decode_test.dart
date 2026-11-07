// PostgresExecutor.decodeValue protects the grid from
// `Instance of 'UndecodedBytes'` rendering. Contracts to pin:
// * Non-bytea UndecodedBytes (custom domains, citext, enums without a
// codec, …) decode to their UTF-8 string — regardless of whether the
// protocol delivered them in text or binary mode — so cells display
// real text and the same string flows back as `oldValue` in
// IS NOT DISTINCT FROM updates.
// * Actual bytea (OID 17) renders as `\xDEADBEEF` — PG's canonical bytea
// text I/O — so bytea columns stay editable.
// * Everything the driver decodes into a Dart object with no Postgres-text
// form (Interval, Time, Uint8List, array columns) becomes the text
// Postgres prints, so the grid shows it and an edit can send it back as
// the old value. A List in a non-array column (jsonb) is left alone.
// * money, inet, cidr, macaddr, timetz and bit arrive as binary bytes with
// no codec; they are decoded from their binary layout, never read as
// UTF-8. (Layouts are from the Postgres docs, not checked against a live
// server here.)

import 'dart:convert';
import 'dart:typed_data';

import 'package:dbscope/db/postgres_executor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart' as pg;

void main() {
  group('PostgresExecutor.decodeValue', () {
    test('passes plain values through unchanged', () {
      expect(PostgresExecutor.decodeValue(null), isNull);
      expect(PostgresExecutor.decodeValue(42), 42);
      expect(PostgresExecutor.decodeValue('hello'), 'hello');
      expect(PostgresExecutor.decodeValue(true), true);
    });

    test('text-format UndecodedBytes → decoded String', () {
      final bytes = Uint8List.fromList(utf8.encode('citext-value'));
      final undecoded = pg.UndecodedBytes(
        typeOid: 0,
        isBinary: false,
        bytes: bytes,
        encoding: utf8,
      );
      expect(PostgresExecutor.decodeValue(undecoded), 'citext-value');
    });

    test('binary UndecodedBytes for non-bytea OID → decoded String', () {
      // Custom domains, citext, and any other type without a registered codec
      // come back as binary UndecodedBytes — but the bytes are still UTF-8.
      final bytes = Uint8List.fromList(utf8.encode('robmllze@gmail.com'));
      final undecoded = pg.UndecodedBytes(
        typeOid: 0,
        isBinary: true,
        bytes: bytes,
        encoding: utf8,
      );
      expect(PostgresExecutor.decodeValue(undecoded), 'robmllze@gmail.com');
    });

    test(r'bytea (OID 17) → PG-canonical \x hex string', () {
      final bytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]);
      final undecoded = pg.UndecodedBytes(
        typeOid: 17,
        isBinary: true,
        bytes: bytes,
        encoding: utf8,
      );
      expect(PostgresExecutor.decodeValue(undecoded), r'\xdeadbeef0001');
    });

    group('driver-decoded objects become Postgres text', () {
      test('interval', () {
        expect(
          PostgresExecutor.decodeValue(pg.Interval(days: 1, microseconds: 7200 * 1000000)),
          '1 day 02:00:00',
        );
        expect(
          PostgresExecutor.decodeValue(pg.Interval(months: 14, days: 3, microseconds: 1500000)),
          '1 year 2 mons 3 days 00:00:01.5',
        );
        expect(PostgresExecutor.decodeValue(pg.Interval(microseconds: -3600 * 1000000)), '-01:00:00');
        expect(PostgresExecutor.decodeValue(pg.Interval()), '00:00:00');
      });

      test('time', () {
        final time = pg.Time(10, 11, 12);
        expect(PostgresExecutor.decodeValue(time), '10:11:12');
      });

      test('bytea decoded to bytes keeps the canonical hex form', () {
        expect(PostgresExecutor.decodeValue(Uint8List.fromList([0xde, 0xad, 0xbe, 0xef])), r'\xdeadbeef');
      });

      test('array columns become array literals', () {
        expect(PostgresExecutor.decodeValue([1, 2], isArray: true), '{1,2}');
        expect(
          PostgresExecutor.decodeValue(['a b', 'say "hi"', null, r'c\d'], isArray: true),
          r'{"a b","say \"hi\"",NULL,"c\\d"}',
        );
        expect(
          PostgresExecutor.decodeValue([
            [1, 2],
            [3, 4],
          ], isArray: true),
          '{{1,2},{3,4}}',
        );
      });

      test('a List in a non-array column (jsonb) is left alone', () {
        final list = [1, 2];
        expect(PostgresExecutor.decodeValue(list), same(list));
      });
    });

    group('binary types without a codec', () {
      Object? decode(int oid, List<int> bytes) => PostgresExecutor.decodeValue(
        pg.UndecodedBytes(
          typeOid: oid,
          isBinary: true,
          bytes: Uint8List.fromList(bytes),
          encoding: utf8,
        ),
      );

      test('money', () {
        expect(decode(790, [0, 0, 0, 0, 0, 0, 0x04, 0xd2]), '12.34');
        expect(decode(790, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfb, 0x2e]), '-12.34');
      });

      test('inet and cidr', () {
        expect(decode(869, [2, 32, 0, 4, 10, 0, 0, 1]), '10.0.0.1');
        expect(decode(869, [2, 24, 0, 4, 10, 0, 0, 1]), '10.0.0.1/24');
        expect(decode(650, [2, 8, 1, 4, 10, 0, 0, 0]), '10.0.0.0/8');
        expect(decode(869, [3, 128, 0, 16, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]), '2001:db8::1');
        expect(decode(869, [3, 128, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]), '::1');
      });

      test('macaddr', () {
        expect(decode(829, [0x08, 0x00, 0x2b, 0x01, 0x02, 0x03]), '08:00:2b:01:02:03');
      });

      test('timetz', () {
        // 10:00:00 at +02 (stored as 7200 seconds west -> -7200).
        const micros = 10 * 3600 * 1000000;
        final bytes = ByteData(12)
          ..setInt64(0, micros)
          ..setInt32(8, -7200);
        expect(decode(1266, bytes.buffer.asUint8List()), '10:00:00+02');
      });

      test('bit', () {
        expect(decode(1560, [0, 0, 0, 5, 0xa8]), '10101');
      });

      test('unknown binary type with UTF-8 bytes still decodes as text', () {
        expect(decode(0, utf8.encode('citext')), 'citext');
      });
    });
  });
}
