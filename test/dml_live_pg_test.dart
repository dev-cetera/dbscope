// Cell edits against a real Postgres, for the column types whose
// optimistic-concurrency guard can't be checked by looking at the SQL:
// `json` and `xml` have no `=` operator, so the guard must still parse and
// match the value the driver handed back when the row was read. Skipped
// unless DBSCOPE_LIVE_PG is set:
//
//   DBSCOPE_LIVE_PG=1 PGHOST=localhost PGUSER=postgres PGPASSWORD=… \
//     fvm flutter test test/dml_live_pg_test.dart
//
// Creates and drops a temporary table; touches nothing else.

import 'dart:io';

import 'package:dbscope/catalog/pg_type.dart';
import 'package:dbscope/db/dml.dart';
import 'package:dbscope/db/edit_policy.dart';
import 'package:dbscope/db/postgres_executor.dart';
import 'package:dbscope/db/postgres_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

String _env(String name, String fallback) => Platform.environment[name] ?? fallback;

EditPolicy _policy(String column, PgType type, String typeName) => EditPolicy(
  schema: 'pg_temp',
  table: 'dbscope_dml_live',
  pkColumns: const ['id'],
  column: column,
  type: type,
  typeName: typeName,
  nullable: true,
  isGenerated: false,
  isIdentity: false,
  readOnly: false,
  multiLine: false,
  nullIfBlank: false,
);

void main() {
  final enabled = Platform.environment['DBSCOPE_LIVE_PG'] != null;

  group('live Postgres cell edits', skip: !enabled, () {
    late PostgresExecutor executor;

    setUpAll(() async {
      executor = PostgresExecutor(
        await PostgresKindPlugin.openConnection(
          host: _env('PGHOST', 'localhost'),
          port: int.parse(_env('PGPORT', '5432')),
          database: _env('PGDATABASE', 'postgres'),
          username: _env('PGUSER', 'postgres'),
          password: _env('PGPASSWORD', ''),
        ),
      );
      await executor.execute(
        'CREATE TEMP TABLE dbscope_dml_live (id int PRIMARY KEY, doc json, x xml)',
      );
      await executor.execute(
        '''INSERT INTO dbscope_dml_live VALUES (1, '{"a": 1}', '<a/>')''',
      );
    });

    tearDownAll(() => executor.close());

    Future<Object?> read(String column) async =>
        (await executor.execute('SELECT $column FROM dbscope_dml_live WHERE id = 1')).rows.first.first;

    test('a json cell edit matches the value read back and saves', () async {
      final result = await CellEditor(executor).updateCell(
        policy: _policy('doc', PgType.json, 'json'),
        pkValues: {'id': 1},
        oldValue: await read('doc'),
        newValueRaw: '{"a": 2}',
      );
      expect(result.affectedRows, 1);
      expect(await read('doc'), {'a': 2});
    });

    test('an xml cell edit matches the value read back and saves', () async {
      final result = await CellEditor(executor).updateCell(
        policy: _policy('x', PgType.unknown, 'xml'),
        pkValues: {'id': 1},
        oldValue: await read('x'),
        newValueRaw: '<b/>',
      );
      expect(result.affectedRows, 1);
      expect(await read('x'), '<b/>');
    });
  });
}
