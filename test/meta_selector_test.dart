// Contract: the selector grammar in plan.md "Selectors".
//
// - `*`, `schema`, `schema.table`, `schema.table.column`, `query:<id>`,
//   `query:<id>.<column>`; anything else (empty segments, unbalanced
//   quotes, four segments) fails to parse rather than matching nothing.
// - Segments are literals (case-sensitive), quoted literals (Postgres
//   rules, so dots and `*` are literal inside quotes) or globs (`*` = any
//   run of characters inside one segment).
// - Table- and schema-level selectors apply to every column inside;
//   column-level selectors never apply to a table as a whole.
// - Specificity: depth first, then segment score (literal 2, partial
//   glob 1, `*` 0).

import 'package:dbscope/meta/selector.dart';
import 'package:flutter_test/flutter_test.dart';

Selector sel(String raw) => Selector.tryParse(raw)!;

void main() {
  group('parsing', () {
    test('accepts every documented form', () {
      for (final raw in [
        '*',
        'public',
        'public.items',
        'public.items.name',
        '*.*.email',
        '*.*.*_internal',
        '"my.schema"."Odd Table"',
        'query:overdue',
        'query:overdue.due_at',
        'query:*',
      ]) {
        expect(Selector.tryParse(raw), isNotNull, reason: raw);
      }
    });

    test('rejects malformed selectors', () {
      for (final raw in [
        '',
        'a..b',
        '.a',
        'a.',
        'a.b.c.d',
        '"unbalanced',
        'query:',
        'query:a.b.c',
        '"a"b',
      ]) {
        expect(Selector.tryParse(raw), isNull, reason: raw);
      }
    });
  });

  group('matching', () {
    test('literals are exact and case-sensitive', () {
      expect(sel('public.items').matchesTable('public', 'items'), isTrue);
      expect(sel('public.items').matchesTable('public', 'Items'), isFalse);
      expect(sel('public.items').matchesTable('other', 'items'), isFalse);
    });

    test('quoted segments keep dots and stars literal', () {
      final s = sel('"my.schema"."a*b"');
      expect(s.matchesTable('my.schema', 'a*b'), isTrue);
      expect(s.matchesTable('my.schema', 'aXb'), isFalse);
    });

    test('a doubled quote inside quotes is one quote', () {
      expect(
        sel('public."say ""hi"""').matchesTable('public', 'say "hi"'),
        isTrue,
      );
    });

    test('globs match within one segment', () {
      final s = sel('*.*.*_internal');
      expect(s.matchesColumn('public', 'users', 'notes_internal'), isTrue);
      expect(s.matchesColumn('public', 'users', 'notes'), isFalse);
      expect(sel('public.user*').matchesTable('public', 'users'), isTrue);
      expect(sel('public.user*').matchesTable('public', 'accounts'), isFalse);
    });

    test('table and schema selectors cover their columns', () {
      expect(
        sel('public.users').matchesColumn('public', 'users', 'email'),
        isTrue,
      );
      expect(sel('public').matchesColumn('public', 'users', 'email'), isTrue);
      expect(sel('*').matchesColumn('a', 'b', 'c'), isTrue);
    });

    test('column selectors never apply to a whole table', () {
      expect(
        sel('public.users.email').matchesTable('public', 'users'),
        isFalse,
      );
    });

    test('query selectors only match queries, `*` matches both', () {
      expect(sel('query:q1').matchesQuery('q1'), isTrue);
      expect(sel('query:q1').matchesTable('query', 'q1'), isFalse);
      expect(sel('query:q1.col').matchesQueryColumn('q1', 'col'), isTrue);
      expect(sel('query:q1').matchesQueryColumn('q1', 'col'), isTrue);
      expect(sel('public.*').matchesQuery('q1'), isFalse);
      expect(sel('*').matchesQuery('q1'), isTrue);
    });
  });

  group('specificity', () {
    test('depth dominates score', () {
      // *.*.email (column, score 2) beats public.users (table, score 4).
      expect(
        sel('*.*.email').specificity,
        greaterThan(sel('public.users').specificity),
      );
    });

    test('literal beats partial glob beats wildcard at equal depth', () {
      expect(
        sel('public.billing').specificity,
        greaterThan(sel('public.bill*').specificity),
      );
      expect(
        sel('public.bill*').specificity,
        greaterThan(sel('public.*').specificity),
      );
      expect(sel('public.*').specificity, greaterThan(sel('*.*').specificity));
    });

    test('exact accessors only answer for glob-free selectors', () {
      expect(sel('public.items').exactTable, (
        schema: 'public',
        table: 'items',
      ));
      expect(sel('public.*').exactTable, isNull);
      expect(sel('query:q1.c').exactQueryId, 'q1');
      expect(sel('query:q1.c').exactColumnName, 'c');
    });
  });
}
