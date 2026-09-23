// PostgresExecutor.decodeValue protects the grid from
// `Instance of 'UndecodedBytes'` rendering. Contracts to pin:
// * Non-bytea UndecodedBytes (custom domains, citext, enums without a
// codec, …) decode to their UTF-8 string — regardless of whether the
// protocol delivered them in text or binary mode — so cells display
// real text and the same string flows back as `oldValue` in
// IS NOT DISTINCT FROM updates.
// * Actual bytea (OID 17) renders as `\xDEADBEEF` — PG's canonical bytea
// text I/O — so bytea columns stay editable.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart' as pg;

import 'package:dbscope/db/postgres_executor.dart';

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

    test('bytea (OID 17) → PG-canonical \\x hex string', () {
      final bytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]);
      final undecoded = pg.UndecodedBytes(
        typeOid: 17,
        isBinary: true,
        bytes: bytes,
        encoding: utf8,
      );
      expect(PostgresExecutor.decodeValue(undecoded), r'\xdeadbeef0001');
    });
  });
}
