// containsMultipleStatements is the "one statement at a time" guard in
// the Query tab (QueryRunner.runSql) and part of the AI read-only gate
// (enforceReadOnly). It must flag a real top-level `;` followed by more
// SQL, and ignore every `;` the Postgres lexer would not split on:
// * inside '' strings (with '' doubling) and E'' escape strings (\'
// escapes; E only counts as a prefix, never as an identifier's tail);
// * inside $$ / $tag$ dollar-quoted bodies, which close only on the
// exact opening delimiter ($1-style positional params are not quotes,
// nor is a `$` inside an identifier);
// * inside "" quoted identifiers, -- line comments and (nested) /* */
// block comments.
// A single trailing `;` followed only by whitespace or comments is ONE
// statement. stripCommentsAndLeading drops leading whitespace and
// comments and stops at the first real token.
// With SqlDialect.sqlite the Postgres-only syntax is off — no E''
// escapes, no dollar quotes, no nested comments — so none of it can hide a
// real second statement from the check.

import 'package:dbscope/util/sql_parse.dart';
import 'package:flutter_test/flutter_test.dart';

bool _pgMulti(String sql) =>
    containsMultipleStatements(sql, dialect: SqlDialect.postgres);

String _pgStrip(String sql) =>
    stripCommentsAndLeading(sql, dialect: SqlDialect.postgres);

void main() {
  group('containsMultipleStatements — statement boundaries', () {
    test('a single statement is not multiple', () {
      expect(_pgMulti('SELECT 1'), isFalse);
    });

    test('empty and whitespace-only input is not multiple', () {
      expect(_pgMulti(''), isFalse);
      expect(_pgMulti('  \n\t'), isFalse);
    });

    test('a single trailing semicolon is one statement', () {
      expect(_pgMulti('SELECT 1;'), isFalse);
      expect(
        _pgMulti('SELECT 1;  -- done\n/* really */\n'),
        isFalse,
      );
    });

    test('two statements are multiple', () {
      expect(_pgMulti('SELECT 1; SELECT 2'), isTrue);
      expect(_pgMulti('SELECT 1;\nSELECT 2;'), isTrue);
    });
  });

  group('containsMultipleStatements — string literals', () {
    test('a semicolon inside a string literal is ignored', () {
      expect(_pgMulti("SELECT 'a;b'"), isFalse);
      expect(_pgMulti("SELECT 'a;b'; SELECT 2"), isTrue);
    });

    test("doubled '' stays inside the string", () {
      expect(_pgMulti("SELECT 'it''s; fine'"), isFalse);
      expect(
        _pgMulti("SELECT 'it''s'; DROP TABLE t"),
        isTrue,
      );
    });

    test(r"E'' strings honour backslash-escaped \'", () {
      expect(_pgMulti(r"SELECT E'it\'s; x'"), isFalse);
      expect(_pgMulti(r"SELECT e'it\'s; x'"), isFalse);
      expect(
        _pgMulti(r"SELECT E'a\\'; SELECT 2"),
        isTrue,
      );
    });

    test('an E at the end of an identifier is not an escape prefix', () {
      // `typE` is one identifier, so '...' is a standard string that
      // closes at the quote after the backslash.
      expect(
        _pgMulti(r"SELECT typE'a\'; DROP TABLE t"),
        isTrue,
      );
    });

    test("an E'' string keeps backslash escapes across a continuation", () {
      expect(
        _pgMulti("SELECT E'a'\n'b\\'; c'"),
        isFalse,
      );
    });
  });

  group('containsMultipleStatements — dollar quotes', () {
    test(r'a semicolon inside a $$ body is ignored', () {
      expect(
        _pgMulti(
          r'CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ '
          'LANGUAGE plpgsql',
        ),
        isFalse,
      );
      expect(
        _pgMulti(
          r"DO $$ BEGIN RAISE NOTICE 'x'; PERFORM 1; END $$;",
        ),
        isFalse,
      );
    });

    test(r'a semicolon inside a $tag$ body is ignored', () {
      expect(
        _pgMulti(
          r'CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END; '
          r'$body$ LANGUAGE plpgsql',
        ),
        isFalse,
      );
      expect(
        _pgMulti(r'SELECT $fn$ a $$; b $fn$; SELECT 2'),
        isTrue,
      );
    });

    test('a different tag does not close the body', () {
      expect(
        _pgMulti(r'SELECT $a$ x $b$; SELECT 2'),
        isFalse,
      );
      expect(
        _pgMulti(r'SELECT $a$ x $A$; SELECT 2'),
        isFalse,
      );
      expect(
        _pgMulti(r'SELECT $a$ x $b$; y $a$; SELECT 2'),
        isTrue,
      );
    });

    test(r'a $1 positional parameter is not a dollar quote', () {
      expect(
        _pgMulti(
          r'UPDATE t SET a = $1 WHERE id = $2; DELETE FROM t',
        ),
        isTrue,
      );
      expect(_pgMulti(r'SELECT $1, $2;'), isFalse);
    });

    test(r'a $ inside an identifier does not open a dollar quote', () {
      expect(_pgMulti(r'SELECT a$$b; SELECT 2'), isTrue);
    });
  });

  group('containsMultipleStatements — identifiers and comments', () {
    test('a semicolon inside a quoted identifier is ignored', () {
      expect(_pgMulti('SELECT "a;b" FROM t'), isFalse);
      expect(_pgMulti('SELECT "a"";b" FROM t'), isFalse);
      expect(_pgMulti('SELECT "a;b"; SELECT 2'), isTrue);
    });

    test('a semicolon inside a -- comment is ignored', () {
      expect(_pgMulti('SELECT 1 -- ; SELECT 2'), isFalse);
      expect(
        _pgMulti('SELECT 1 -- note\n; SELECT 2'),
        isTrue,
      );
    });

    test(r'a -- comment also ends at \r', () {
      expect(_pgMulti('SELECT 1; -- c\rSELECT 2'), isTrue);
    });

    test('a semicolon inside a /* */ comment is ignored', () {
      expect(_pgMulti('SELECT /* ; */ 1'), isFalse);
      expect(
        _pgMulti('SELECT 1 /* ; */; SELECT 2'),
        isTrue,
      );
    });

    test('block comments nest', () {
      expect(_pgMulti('SELECT /* a /* b */ ; */ 1'), isFalse);
    });

    test('quotes inside comments do not open strings', () {
      expect(
        _pgMulti("SELECT 1 -- it's\n; SELECT 2"),
        isTrue,
      );
      expect(
        _pgMulti("SELECT 1 /* it's */; SELECT 2"),
        isTrue,
      );
    });

    test('comment markers inside strings do not open comments', () {
      expect(_pgMulti("SELECT '--'; SELECT 2"), isTrue);
      expect(_pgMulti("SELECT '/*'; SELECT 2"), isTrue);
    });
  });

  group('stripCommentsAndLeading', () {
    test('returns the input unchanged when it starts with a token', () {
      expect(_pgStrip('SELECT 1'), 'SELECT 1');
    });

    test('drops leading whitespace and comments only', () {
      expect(
        _pgStrip('  -- a\n/* b */\n\tSELECT 1 -- tail'),
        'SELECT 1 -- tail',
      );
    });

    test(r'a leading -- comment ends at \r', () {
      expect(_pgStrip('-- a\rSELECT 1'), 'SELECT 1');
    });

    test('nested block comments are dropped whole', () {
      expect(
        _pgStrip('/* a /* b */ c */ SELECT 1'),
        'SELECT 1',
      );
    });

    test('input that is only comments becomes empty', () {
      expect(_pgStrip(' -- a\n /* b */ '), isEmpty);
      expect(_pgStrip('/* unterminated'), isEmpty);
    });

    test('stops at a leading string literal', () {
      expect(_pgStrip("'--x' AS a"), "'--x' AS a");
    });
  });

  group('SqlDialect.sqlite', () {
    bool multi(String sql) =>
        containsMultipleStatements(sql, dialect: SqlDialect.sqlite);

    test("a backslash doesn't escape a quote", () {
      // SQLite reads `E` `'\'` then a real second statement.
      expect(multi(r"SELECT E'\'; DELETE FROM t; --'"), isTrue);
      expect(_pgMulti(r"SELECT E'\'; DELETE FROM t; --'"), isFalse);
    });

    test('dollar signs are bind parameters, not quotes', () {
      expect(multi(r'SELECT $x$; DELETE FROM t; $x$'), isTrue);
      expect(multi(r'SELECT * FROM t WHERE id = $id'), isFalse);
    });

    test('block comments end at the first */', () {
      expect(multi('SELECT 1 /* a /* b */; DELETE FROM t'), isTrue);
      expect(
        stripCommentsAndLeading(
          '/* a /* b */ SELECT 1',
          dialect: SqlDialect.sqlite,
        ),
        'SELECT 1',
      );
    });

    test('standard strings, identifiers and comments still hide ;', () {
      expect(multi("SELECT 'a;b', \"c;d\" -- e;f\n"), isFalse);
      expect(multi('SELECT 1;'), isFalse);
      expect(multi('SELECT 1; SELECT 2'), isTrue);
    });
  });
}
