// Column types drive how cell edits are parsed (`CellEditor.parseValue`):
// an int type means `int.parse`, anything text-ish is sent as a string.
// * Postgres udt names map exactly; unknown names (enums, ranges,
//   geometric and extension types) are PgType.unknown, never guessed by
//   substring — `appointment_status` contains "INT" but is not an int.
// * SQLite declared types follow SQLite's affinity rules, where an "INT"
//   substring really does mean integer affinity (even for POINT).

import 'package:dbscope/catalog/pg_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pgTypeFromUdt', () {
    test('maps canonical udt names', () {
      expect(pgTypeFromUdt('int4'), PgType.int4);
      expect(pgTypeFromUdt('int8'), PgType.int8);
      expect(pgTypeFromUdt('varchar'), PgType.varchar);
      expect(pgTypeFromUdt('timestamptz'), PgType.timestamptz);
      expect(pgTypeFromUdt('jsonb'), PgType.jsonb);
      expect(pgTypeFromUdt('citext'), PgType.text);
    });

    test('leading underscore is an array', () {
      expect(pgTypeFromUdt('_int4'), PgType.array);
      expect(pgTypeFromUdt('_text'), PgType.array);
    });

    test('unlisted names are unknown, not substring-guessed', () {
      for (final udt in [
        'appointment_status',
        'integration_state',
        'point',
        'int4range',
        'int8range',
        'tsvector',
        'inet',
      ]) {
        expect(pgTypeFromUdt(udt), PgType.unknown, reason: udt);
      }
    });
  });

  group('pgTypeFromSqlite', () {
    test('INT anywhere means integer affinity', () {
      expect(pgTypeFromSqlite('INTEGER'), PgType.int8);
      expect(pgTypeFromSqlite('bigint'), PgType.int8);
      expect(pgTypeFromSqlite('POINT'), PgType.int8);
    });

    test('text and other declared types', () {
      expect(pgTypeFromSqlite('VARCHAR(255)'), PgType.text);
      expect(pgTypeFromSqlite('TEXT'), PgType.text);
      expect(pgTypeFromSqlite('BLOB'), PgType.bytea);
      expect(pgTypeFromSqlite('NUMERIC(10,2)'), PgType.numeric);
      expect(pgTypeFromSqlite(''), PgType.unknown);
    });
  });
}
