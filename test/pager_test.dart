// KeysetPager is what makes "browse a billion-row table" feasible. The
// critical invariants:
// * Pages use a tuple-compare keyset cursor, not OFFSET.
// * Placeholder numbering for the optional baseWhere starts at $1; the
// keyset cursor uses placeholders strictly above baseWhereParams.
// * Tables without a PK (information_schema views, ad-hoc relations)
// get a single LIMIT page with no ORDER BY tuple-compare.
// * Descending sort flips both the ORDER BY direction and the
// tuple-compare operator (`<` vs `>`).

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/catalog/pg_type.dart';
import 'package:dbscope/catalog/schema_catalog.dart';
import 'package:dbscope/db/executor.dart';
import 'package:dbscope/query/pager.dart';

import 'support/fake_executor.dart';

ColumnInfo _col(String name) => ColumnInfo(
  name: name,
  type: PgType.text,
  typeName: 'text',
  nullable: true,
  defaultExpr: null,
  isGenerated: false,
  isIdentity: false,
);

DbResult _rows(List<List<Object?>> rows) =>
    DbResult(columns: const [], rows: rows);

void main() {
  group('KeysetPager — happy path with PK', () {
    test('first page has no cursor WHERE; ORDER BY is PK ascending', () async {
      final exec = FakeDbExecutor();
      exec.enqueue(
        _rows([
          [1, 'a'],
          [2, 'b'],
        ]),
      );

      final pager = KeysetPager(
        conn: exec,
        schema: 'public',
        table: 'users',
        columns: [_col('id'), _col('name')],
        pkColumns: const ['id'],
        pageSize: 2,
      );

      final page = await pager.fetchNext();
      expect(page.rows, hasLength(2));
      expect(page.lastPkVals, [2]);

      final call = exec.calls.single;
      expect(
        call.sql,
        'SELECT "id", "name" FROM "public"."users" ORDER BY "id" ASC LIMIT 2',
      );
      expect(call.positional, isNull);
    });

    test('second page applies (pk) > (lastPk) tuple-compare cursor', () async {
      final exec = FakeDbExecutor();
      exec.enqueue(
        _rows([
          [1],
          [2],
        ]),
      );
      exec.enqueue(
        _rows([
          [3],
        ]),
      );

      final pager = KeysetPager(
        conn: exec,
        schema: 'public',
        table: 'users',
        columns: [_col('id')],
        pkColumns: const ['id'],
        pageSize: 2,
      );

      await pager.fetchNext();
      await pager.fetchNext();

      final secondCall = exec.calls[1];
      expect(
        secondCall.sql,
        'SELECT "id" FROM "public"."users" WHERE ("id") > (\$1) ORDER BY "id" ASC LIMIT 2',
      );
      expect(secondCall.positional, [2]);
    });

    test(
      'descending sort flips ORDER BY direction and uses `<` cursor',
      () async {
        final exec = FakeDbExecutor();
        exec.enqueue(
          _rows([
            [10],
            [9],
          ]),
        );
        exec.enqueue(
          _rows([
            [8],
          ]),
        );

        final pager = KeysetPager(
          conn: exec,
          schema: 'public',
          table: 'users',
          columns: [_col('id')],
          pkColumns: const ['id'],
          descending: true,
          pageSize: 2,
        );

        await pager.fetchNext();
        await pager.fetchNext();

        final second = exec.calls[1];
        expect(second.sql, contains('ORDER BY "id" DESC'));
        expect(second.sql, contains('WHERE ("id") < (\$1)'));
        expect(second.positional, [9]);
      },
    );

    test('explicit sortColumn is prepended to the keyset tuple', () async {
      final exec = FakeDbExecutor();
      exec.enqueue(
        _rows([
          ['Alice', 1],
          ['Bob', 2],
        ]),
      );
      exec.enqueue(
        _rows([
          ['Carol', 3],
        ]),
      );

      final pager = KeysetPager(
        conn: exec,
        schema: 'public',
        table: 'users',
        columns: [_col('name'), _col('id')],
        pkColumns: const ['id'],
        sortColumn: 'name',
        pageSize: 2,
      );

      await pager.fetchNext();
      await pager.fetchNext();

      final second = exec.calls[1];
      expect(
        second.sql,
        contains(
          'WHERE ("name", "id") > (\$1, \$2) ORDER BY "name" ASC, "id" ASC',
        ),
      );
      expect(second.positional, ['Bob', 2]);
    });

    test('a short page marks the pager done', () async {
      final exec = FakeDbExecutor();
      exec.enqueue(
        _rows([
          [1],
        ]),
      );

      final pager = KeysetPager(
        conn: exec,
        schema: 'public',
        table: 'users',
        columns: [_col('id')],
        pkColumns: const ['id'],
        pageSize: 100,
      );

      await pager.fetchNext();
      expect(pager.isDone, isTrue);

      // Further fetchNext returns an empty page without touching the executor.
      final empty = await pager.fetchNext();
      expect(empty.rows, isEmpty);
      expect(exec.calls, hasLength(1));
    });
  });

  group('KeysetPager — baseWhere placeholder numbering', () {
    test('baseWhere params take \$1..\$N, cursor params follow', () async {
      final exec = FakeDbExecutor();
      exec.enqueue(
        _rows([
          [1],
          [2],
        ]),
      );
      exec.enqueue(
        _rows([
          [3],
        ]),
      );

      final pager = KeysetPager(
        conn: exec,
        schema: 'public',
        table: 'items',
        columns: [_col('id')],
        pkColumns: const ['id'],
        pageSize: 2,
        baseWhere: '"group_id" = \$1 AND "deleted_at" IS NULL',
        baseWhereParams: const ['g123'],
      );

      await pager.fetchNext();
      // First page: baseWhere only, no cursor yet.
      final first = exec.calls.first;
      expect(
        first.sql,
        contains(
          'WHERE "group_id" = \$1 AND "deleted_at" IS NULL ORDER BY "id" ASC',
        ),
      );
      expect(first.positional, ['g123']);

      await pager.fetchNext();
      // Second page: baseWhere ($1) AND cursor ($2).
      final second = exec.calls[1];
      expect(
        second.sql,
        contains(
          'WHERE "group_id" = \$1 AND "deleted_at" IS NULL AND ("id") > (\$2)',
        ),
      );
      expect(second.positional, ['g123', 2]);
    });
  });

  group('KeysetPager — no PK', () {
    test('streaming via pages() emits a single LIMIT page', () async {
      final exec = FakeDbExecutor();
      exec.enqueue(
        _rows([
          [1, 'a'],
          [2, 'b'],
        ]),
      );

      final pager = KeysetPager(
        conn: exec,
        schema: 'information_schema',
        table: 'columns',
        columns: [_col('a'), _col('b')],
        pkColumns: const [],
        pageSize: 50,
      );

      final pages = await pager.pages().toList();
      expect(pages, hasLength(1));
      expect(pages.single.rows, hasLength(2));

      final call = exec.calls.single;
      // SELECT * is the no-PK fast path; no ORDER BY tuple, just LIMIT.
      expect(
        call.sql,
        'SELECT * FROM "information_schema"."columns" LIMIT 50',
      );
      expect(call.positional, isNull);
    });

    test('no-PK with baseWhere passes params and adds WHERE clause', () async {
      final exec = FakeDbExecutor();
      exec.enqueue(
        _rows([
          [1],
        ]),
      );

      final pager = KeysetPager(
        conn: exec,
        schema: 'public',
        table: 'view_x',
        columns: [_col('id')],
        pkColumns: const [],
        pageSize: 100,
        baseWhere: '"flag" = \$1',
        baseWhereParams: const [true],
      );

      await pager.pages().toList();

      final call = exec.calls.single;
      expect(
        call.sql,
        'SELECT * FROM "public"."view_x" WHERE "flag" = \$1 LIMIT 100',
      );
      expect(call.positional, [true]);
    });

    test('isDone after a single no-PK page', () async {
      final exec = FakeDbExecutor();
      exec.enqueue(
        _rows([
          [1],
        ]),
      );

      final pager = KeysetPager(
        conn: exec,
        schema: 'information_schema',
        table: 'views',
        columns: [_col('a')],
        pkColumns: const [],
      );

      await pager.pages().toList();
      expect(pager.isDone, isTrue);
    });
  });
}
