// Regression tests for the bugs fixed together from BUGS.md (2026-11-03).
// Each group names the contract it pins:
// * A reply that is only `-- CLARIFY: <question>` yields the question.
// * enforceReadOnly refuses write keywords anywhere outside literals and
//   comments (data-modifying CTEs, EXPLAIN ANALYZE DELETE, SELECT INTO),
//   but not inside a string or a quoted identifier.
// * The SQLite placeholder translator turns a Postgres type on a
//   placeholder (`@x:int8`, `$1::int8`) into a CAST or drops it.
// * SqliteExecutor returns the rows of a bound query whatever it starts
//   with (a comment), matches `dbscope_iregexp`, and stops
//   a statement at its timeout.
// * A date-only value is UTC midnight of that day for the timestamp
//   renderer, wherever the viewer is.
// * Built-in Postgres type oids map to type names; arrays classify as
//   arrays.
// * readOnlyHeuristic matches prod/live/main only as words of their own;
//   suggestReadOnly (the dialog's default) also writes local hosts and
//   guards remote ones.
// * A connection link with an absurd iteration count or a malformed nonce
//   is refused as a FormatException without running the KDF.
// * uniqueColumnNames suffixes duplicates.

import 'dart:convert';

import 'package:dbscope/ai/sql_assistant.dart';
import 'package:dbscope/catalog/pg_type.dart';
import 'package:dbscope/connection/connection_link.dart';
import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/postgres_executor.dart';
import 'package:dbscope/db/sqlite_executor.dart';
import 'package:dbscope/db/sqlite_param_translator.dart';
import 'package:dbscope/db/statement_timeout.dart';
import 'package:dbscope/grid/export_names.dart';
import 'package:dbscope/meta/meta_models.dart';
import 'package:dbscope/meta/value_format.dart';
import 'package:dbscope/util/sql_parse.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

void _refuses(String sql, {SqlDialect dialect = SqlDialect.postgres}) => expect(
  () => enforceReadOnly(sql, dialect: dialect),
  throwsA(isA<AssistantException>()),
  reason: sql,
);

void _allows(String sql, {SqlDialect dialect = SqlDialect.postgres}) =>
    expect(() => enforceReadOnly(sql, dialect: dialect), returnsNormally, reason: sql);

void main() {
  group('enforceReadOnly', () {
    test('refuses writes hidden behind an allowed first word', () {
      _refuses('WITH d AS (DELETE FROM public.items RETURNING *) SELECT * FROM d');
      _refuses('EXPLAIN ANALYZE DELETE FROM public.items');
      _refuses('with x as (update t set a = 1 returning a) select * from x');
      _refuses('WITH c AS (SELECT 1) INSERT INTO t SELECT * FROM c', dialect: SqlDialect.sqlite);
      _refuses('WITH c AS (SELECT 1) REPLACE INTO t SELECT * FROM c', dialect: SqlDialect.sqlite);
      _refuses('SELECT * INTO new_table FROM t');
    });

    test('allows reads, including write words inside literals and quotes', () {
      _allows('SELECT * FROM t');
      _allows('WITH x AS (SELECT 1) SELECT * FROM x');
      _allows('EXPLAIN SELECT * FROM t');
      _allows("SELECT 'DELETE FROM t' AS s");
      _allows('SELECT "update" FROM t');
      _allows('SELECT 1 -- delete everything\n');
      _allows("SELECT replace(name, 'a', 'b'), comment FROM t");
    });
  });

  group('SQLite placeholder translator', () {
    test('driver annotation becomes a CAST for known affinities', () {
      expect(translateNamedToSqlite('WHERE id = @id:int8'), 'WHERE id = CAST(:id AS INTEGER)');
      expect(translateNamedToSqlite('WHERE n = @n::text'), 'WHERE n = CAST(:n AS TEXT)');
      expect(translateNamedToSqlite('WHERE u = @u:uuid'), 'WHERE u = :u');
      expect(translateNamedToSqlite('WHERE a = @a'), 'WHERE a = :a');
    });

    test('positional cast becomes a CAST or is dropped', () {
      expect(translatePositionalToSqlite(r'WHERE id = $1::int8'), 'WHERE id = CAST(?1 AS INTEGER)');
      expect(translatePositionalToSqlite(r'WHERE t = $2::timestamptz'), 'WHERE t = ?2');
      expect(translatePositionalToSqlite(r'WHERE x = ANY($1::int4[])'), 'WHERE x = ANY(?1)');
      expect(translatePositionalToSqlite(r'WHERE a = $1 AND b = $2'), 'WHERE a = ?1 AND b = ?2');
    });
  });

  group('SqliteExecutor', () {
    late SqliteExecutor executor;

    setUp(() {
      final db = sq.sqlite3.openInMemory();
      executor = SqliteExecutor(db);
      db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      db.execute("INSERT INTO t (name) VALUES ('Alpha'), ('beta'), ('gamma')");
    });

    tearDown(() => executor.close());

    test('a bound query that starts with a comment returns rows', () async {
      final commented = await executor.execute(
        '-- all rows\nSELECT id FROM t WHERE id > @min',
        named: {'min': 0},
      );
      expect(commented.rows, hasLength(3));
      final block = await executor.execute(
        r'/* two rows */ SELECT id FROM t WHERE id = $1 UNION SELECT id FROM t WHERE id = $2',
        positional: [1, 2],
      );
      expect(block.rows, hasLength(2));
    });

    test('RETURNING after a newline returns the row', () async {
      final result = await executor.execute(
        'INSERT INTO t (name) VALUES (@n)\nRETURNING id',
        named: {'n': 'delta'},
      );
      expect(result.rows, [
        [4],
      ]);
    });

    test('a typed annotation runs on SQLite', () async {
      final result = await executor.execute(
        'SELECT name FROM t WHERE id = @id:int8',
        named: {'id': 2},
      );
      expect(result.rows, [
        ['beta'],
      ]);
    });

    test('dbscope_iregexp is a case-insensitive regex match', () async {
      final result = await executor.execute(
        r'SELECT id FROM t WHERE dbscope_iregexp($1, CAST(name AS TEXT)) ORDER BY id',
        positional: ['^a|^G'],
      );
      expect(result.rows, [
        [1],
        [3],
      ]);
    });

    test('withStatementTimeout stops a runaway statement', () async {
      const runaway =
          'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) '
          'SELECT count(*) FROM n';
      await expectLater(
        executor.withStatementTimeout(
          const Duration(milliseconds: 200),
          () => executor.execute(runaway),
        ),
        throwsA(isA<StatementTimedOut>()),
      );
      // The connection still works afterwards.
      final after = await executor.execute('SELECT count(*) FROM t');
      expect(after.rows.first.first, 3);
    });
  });

  group('timestamp renderer', () {
    test('a date-only value is UTC midnight of that day', () {
      expect(
        formatForRenderer(ValueRenderer.timestamp, const {'format': 'date'}, '2024-01-01'),
        '2024-01-01',
      );
      expect(
        formatForRenderer(ValueRenderer.timestamp, const {}, '2024-01-01'),
        '2024-01-01 00:00:00 UTC',
      );
    });

    test('zoned and unzoned timestamps keep their meaning', () {
      expect(
        formatForRenderer(ValueRenderer.timestamp, const {}, '2024-01-01 10:00:00'),
        '2024-01-01 10:00:00 UTC',
      );
      expect(
        formatForRenderer(ValueRenderer.timestamp, const {}, '2024-01-01 10:00:00+02'),
        '2024-01-01 08:00:00 UTC',
      );
    });
  });

  group('Postgres type names', () {
    test('built-in oids map to names', () {
      expect(pgTypeNameForOid(2950), 'uuid');
      expect(pgTypeNameForOid(25), 'text');
      expect(pgTypeNameForOid(1007), 'int4[]');
      expect(pgTypeNameForOid(999999), isNull);
    });

    test('array names classify as arrays, not their element', () {
      expect(pgTypeFromTypeName('int4[]'), PgType.array);
      expect(pgTypeFromTypeName('_text'), PgType.array);
      expect(pgTypeFromTypeName('int4'), PgType.int4);
    });
  });

  group('readOnlyHeuristic', () {
    test('matches the words on their own', () {
      for (final name in ['prod', 'Prod DB', 'my-prod', 'main_replica', 'LIVE', 'prod2', 'production']) {
        expect(readOnlyHeuristic.hasMatch(name), isTrue, reason: name);
      }
    });

    test('does not match inside other words', () {
      for (final name in ['Liverpool', 'Olive', 'Domain admin', 'Maintenance', 'Deliveries', 'product']) {
        expect(readOnlyHeuristic.hasMatch(name), isFalse, reason: name);
      }
    });
  });

  group('suggestReadOnly', () {
    test('a prod/live/main name wins, even on localhost', () {
      final s = suggestReadOnly(name: 'Prod replica', host: 'localhost');
      expect(s.readOnly, isTrue);
      expect(s.reason, contains('prod'));
    });

    test('local databases default to writable, remote ones to read-only', () {
      expect(suggestReadOnly(name: 'local', host: 'localhost').readOnly, isFalse);
      expect(suggestReadOnly(name: 'dev', host: '127.0.0.1').readOnly, isFalse);
      expect(suggestReadOnly(name: 'Liverpool', host: 'db.example.com').readOnly, isTrue);
    });
  });

  group('ConnectionLink.decode bounds', () {
    Future<Map<String, Object?>> link() async {
      final text = await ConnectionLink.encode(
        profile: ConnectionProfile(id: 'x', name: 'n', password: 'pw'),
        passphrase: 'pass',
      );
      return jsonDecode(text) as Map<String, Object?>;
    }

    Future<void> decodeWith(void Function(Map<String, Object?> secret) edit) async {
      final doc = await link();
      edit(doc['secret']! as Map<String, Object?>);
      await ConnectionLink.decode(jsonText: jsonEncode(doc), passphrase: 'pass');
    }

    test('an absurd or zero iteration count is refused', () async {
      await expectLater(
        decodeWith((secret) => secret['iterations'] = 2000000000),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        decodeWith((secret) => secret['iterations'] = 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('a short nonce is refused', () async {
      await expectLater(
        decodeWith((secret) => secret['nonce'] = base64.encode([1])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('uniqueColumnNames suffixes duplicates without colliding', () {
    expect(uniqueColumnNames(['id', 'id', 'name', 'ID', 'id_2']), ['id', 'id_3', 'name', 'ID_4', 'id_2']);
  });

  group('clarifyingQuestion', () {
    test('finds the question in a clarifying reply', () {
      expect(clarifyingQuestion('-- CLARIFY: Which table do you mean?'), 'Which table do you mean?');
      expect(clarifyingQuestion('  -- clarify:   Which one?  '), 'Which one?');
    });

    test('a query is not a question', () {
      expect(clarifyingQuestion('SELECT 1'), isNull);
      expect(clarifyingQuestion('-- CLARIFY: Which?\nSELECT 1'), isNull);
      expect(clarifyingQuestion('-- an ordinary comment'), isNull);
    });
  });
}
