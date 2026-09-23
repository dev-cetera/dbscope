// Tests for SQL identifier and literal quoting. These helpers are the
// single line of defence between user input and the SQL we run, so they
// must escape correctly for every shape we expect — embedded quotes,
// schema-qualified names, mixed-type literals.

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/util/sql_quote.dart';

void main() {
  group('quoteIdent', () {
    test('wraps simple identifiers in double quotes', () {
      expect(quoteIdent('users'), '"users"');
    });

    test(
      'preserves case (Postgres identifiers are case-sensitive when quoted)',
      () {
        expect(quoteIdent('MyTable'), '"MyTable"');
      },
    );

    test('escapes embedded double quotes by doubling them', () {
      expect(quoteIdent('weird"name'), '"weird""name"');
    });

    test('handles reserved keyword identifiers', () {
      expect(quoteIdent('group'), '"group"');
      expect(quoteIdent('order'), '"order"');
    });

    test('handles identifier with leading/trailing whitespace verbatim', () {
      expect(quoteIdent(' col '), '" col "');
    });

    test('quotes empty identifier as empty quoted string', () {
      expect(quoteIdent(''), '""');
    });
  });

  group('quoteQualified', () {
    test('joins schema and table with a dot, both quoted', () {
      expect(quoteQualified('public', 'users'), '"public"."users"');
    });

    test('escapes both halves independently', () {
      expect(
        quoteQualified('we"ird', 'tbl"e'),
        '"we""ird"."tbl""e"',
      );
    });

    test('mixed-case schema and table preserved', () {
      expect(
        quoteQualified('MySchema', 'MyTable'),
        '"MySchema"."MyTable"',
      );
    });
  });

  group('quoteLiteral', () {
    test('null renders as NULL (unquoted)', () {
      expect(quoteLiteral(null), 'NULL');
    });

    test('bool renders as TRUE/FALSE (unquoted)', () {
      expect(quoteLiteral(true), 'TRUE');
      expect(quoteLiteral(false), 'FALSE');
    });

    test('int and double render unquoted', () {
      expect(quoteLiteral(42), '42');
      expect(quoteLiteral(3.14), '3.14');
    });

    test('BigInt renders unquoted', () {
      expect(
        quoteLiteral(BigInt.parse('99999999999999999999')),
        '99999999999999999999',
      );
    });

    test('plain string is single-quoted', () {
      expect(quoteLiteral('hello'), "'hello'");
    });

    test('embedded single quotes are doubled', () {
      expect(quoteLiteral("O'Brien"), "'O''Brien'");
    });

    test('empty string renders as empty quoted string', () {
      expect(quoteLiteral(''), "''");
    });

    test('unknown object falls back to toString', () {
      const value = Duration(seconds: 5);
      expect(quoteLiteral(value), "'${value.toString()}'");
    });
  });
}
