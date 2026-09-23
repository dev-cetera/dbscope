// CellEditor produces the SQL that mutates user data. The contract worth
// guarding here:
// * UPDATE always carries the optimistic-concurrency clause
// `IS NOT DISTINCT FROM $oldValue` (CLAUDE.md SQL safety invariants).
// * Identifiers go through quoteIdent — no raw interpolation of user
// column/table names.
// * parseValue coerces strings to typed values per PgType, and honours
// nullIfBlank so an empty grid cell becomes NULL when the column is
// not nullable-blank.

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/catalog/pg_type.dart';
import 'package:dbscope/db/dml.dart';
import 'package:dbscope/db/edit_policy.dart';

import 'support/fake_executor.dart';

EditPolicy _policy({
  String schema = 'public',
  String table = 'users',
  List<String> pkColumns = const ['id'],
  String column = 'name',
  PgType type = PgType.text,
  String typeName = 'text',
  bool nullable = true,
  bool nullIfBlank = false,
}) {
  return EditPolicy(
    schema: schema,
    table: table,
    pkColumns: pkColumns,
    column: column,
    type: type,
    typeName: typeName,
    nullable: nullable,
    isGenerated: false,
    isIdentity: false,
    readOnly: false,
    multiLine: false,
    nullIfBlank: nullIfBlank,
  );
}

void main() {
  group('CellEditor.updateCell', () {
    test('builds UPDATE with quoted identifiers + optimistic guard', () async {
      final exec = FakeDbExecutor();
      exec.enqueueAffected(1);
      final editor = CellEditor(exec);

      final result = await editor.updateCell(
        policy: _policy(),
        pkValues: {'id': 42},
        oldValue: 'Alice',
        newValueRaw: 'Bob',
      );

      expect(result.affectedRows, 1);
      expect(result.newValue, 'Bob');
      expect(exec.calls, hasLength(1));

      final call = exec.calls.single;
      expect(call.sql, contains('UPDATE "public"."users"'));
      expect(call.sql, contains('SET "name" = \$1'));
      expect(call.sql, contains('WHERE "id" = \$2'));
      expect(call.sql, contains('AND "name" IS NOT DISTINCT FROM \$3'));
      // params in order: new value, pk value(s), old value.
      expect(call.positional, ['Bob', 42, 'Alice']);
    });

    test('handles composite primary keys', () async {
      final exec = FakeDbExecutor();
      exec.enqueueAffected(1);
      final editor = CellEditor(exec);

      await editor.updateCell(
        policy: _policy(pkColumns: ['tenant_id', 'id']),
        pkValues: {'tenant_id': 't1', 'id': 'u9'},
        oldValue: 5,
        newValueRaw: '6',
      );

      final call = exec.calls.single;
      expect(call.sql, contains('"tenant_id" = \$2'));
      expect(call.sql, contains('"id" = \$3'));
      expect(call.sql, contains('IS NOT DISTINCT FROM \$4'));
      // Parsed value is still the raw string because the policy type is text.
      expect(call.positional, ['6', 't1', 'u9', 5]);
    });

    test('escapes embedded double quotes in identifiers', () async {
      final exec = FakeDbExecutor();
      exec.enqueueAffected(1);
      final editor = CellEditor(exec);

      await editor.updateCell(
        policy: _policy(
          schema: 'we"ird',
          table: 'tbl"e',
          column: 'col"',
          pkColumns: ['id"'],
        ),
        pkValues: {'id"': 1},
        oldValue: null,
        newValueRaw: 'v',
      );

      final call = exec.calls.single;
      expect(call.sql, contains('"we""ird"."tbl""e"'));
      expect(call.sql, contains('"col"""'));
      expect(call.sql, contains('"id"""'));
    });

    test('zero affected rows means concurrent update was detected', () async {
      final exec = FakeDbExecutor();
      exec.enqueueAffected(0);
      final editor = CellEditor(exec);

      final result = await editor.updateCell(
        policy: _policy(),
        pkValues: {'id': 1},
        oldValue: 'stale',
        newValueRaw: 'next',
      );

      // Caller is expected to interpret 0 affectedRows as a conflict.
      expect(result.affectedRows, 0);
    });
  });

  group('CellEditor.deleteRow', () {
    test('quotes identifiers and uses positional pk params', () async {
      final exec = FakeDbExecutor();
      exec.enqueueAffected(1);
      final editor = CellEditor(exec);

      final n = await editor.deleteRow(
        schema: 'public',
        table: 'users',
        pkColumns: ['id'],
        pkValues: {'id': 7},
      );

      expect(n, 1);
      final call = exec.calls.single;
      expect(call.sql, 'DELETE FROM "public"."users" WHERE "id" = \$1');
      expect(call.positional, [7]);
    });

    test('composite PK builds a chained WHERE', () async {
      final exec = FakeDbExecutor();
      exec.enqueueAffected(1);
      final editor = CellEditor(exec);

      await editor.deleteRow(
        schema: 'public',
        table: 'memberships',
        pkColumns: ['group_id', 'user_id'],
        pkValues: {'group_id': 'g', 'user_id': 'u'},
      );

      final call = exec.calls.single;
      expect(
        call.sql,
        'DELETE FROM "public"."memberships" WHERE "group_id" = \$1 AND "user_id" = \$2',
      );
      expect(call.positional, ['g', 'u']);
    });
  });

  group('CellEditor.insertRow', () {
    test('produces INSERT ... RETURNING * and returns the first row', () async {
      final exec = FakeDbExecutor();
      exec.enqueueRow([1, 'Alice'], columns: ['id', 'name']);
      final editor = CellEditor(exec);

      final returned = await editor.insertRow(
        schema: 'public',
        table: 'users',
        editable: [
          _policy(column: 'id', type: PgType.int4, typeName: 'int4'),
          _policy(column: 'name'),
        ],
        values: {'id': '1', 'name': 'Alice'},
      );

      expect(returned, [1, 'Alice']);
      final call = exec.calls.single;
      expect(
        call.sql,
        'INSERT INTO "public"."users" ("id", "name") VALUES (\$1, \$2) RETURNING *',
      );
      // id was parsed as int, name kept as string.
      expect(call.positional, [1, 'Alice']);
    });

    test('skips columns absent from values map', () async {
      final exec = FakeDbExecutor();
      exec.enqueueRow([1], columns: ['id']);
      final editor = CellEditor(exec);

      await editor.insertRow(
        schema: 'public',
        table: 'users',
        editable: [
          _policy(column: 'id', type: PgType.int4, typeName: 'int4'),
          _policy(column: 'name'),
        ],
        values: {'id': '1'},
      );

      final call = exec.calls.single;
      expect(call.sql, contains('("id")'));
      expect(call.sql, isNot(contains('"name"')));
      expect(call.positional, [1]);
    });

    test('throws when no columns are provided', () async {
      final exec = FakeDbExecutor();
      final editor = CellEditor(exec);

      expect(
        () => editor.insertRow(
          schema: 'public',
          table: 'users',
          editable: [_policy(column: 'name')],
          values: const {},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(exec.calls, isEmpty);
    });
  });

  group('CellEditor.parseValue', () {
    test('null stays null', () {
      expect(CellEditor.parseValue(_policy(), null), isNull);
    });

    test('empty string with nullIfBlank=true → null', () {
      expect(
        CellEditor.parseValue(_policy(nullIfBlank: true), ''),
        isNull,
      );
    });

    test('empty string with nullIfBlank=false → empty string', () {
      expect(
        CellEditor.parseValue(_policy(nullIfBlank: false), ''),
        '',
      );
    });

    test('int types parse to int', () {
      final policy = _policy(type: PgType.int4, typeName: 'int4');
      expect(CellEditor.parseValue(policy, '42'), 42);
    });

    test('int type rejects non-numeric strings', () {
      final policy = _policy(type: PgType.int8, typeName: 'int8');
      expect(
        () => CellEditor.parseValue(policy, 'abc'),
        throwsA(isA<FormatException>()),
      );
    });

    test('numeric/real/doublePrecision parse to num', () {
      final policy = _policy(type: PgType.doublePrecision, typeName: 'float8');
      expect(CellEditor.parseValue(policy, '3.5'), 3.5);
    });

    test('bool accepts true/false/t/f/1/0 case-insensitively', () {
      final policy = _policy(type: PgType.bool_, typeName: 'bool');
      expect(CellEditor.parseValue(policy, 'true'), isTrue);
      expect(CellEditor.parseValue(policy, 'TRUE'), isTrue);
      expect(CellEditor.parseValue(policy, 't'), isTrue);
      expect(CellEditor.parseValue(policy, '1'), isTrue);
      expect(CellEditor.parseValue(policy, 'false'), isFalse);
      expect(CellEditor.parseValue(policy, 'F'), isFalse);
      expect(CellEditor.parseValue(policy, '0'), isFalse);
    });

    test('bool rejects garbage', () {
      final policy = _policy(type: PgType.bool_, typeName: 'bool');
      expect(
        () => CellEditor.parseValue(policy, 'maybe'),
        throwsA(isA<FormatException>()),
      );
    });

    test('json normalises through jsonDecode/jsonEncode', () {
      final policy = _policy(type: PgType.jsonb, typeName: 'jsonb');
      // Extra whitespace collapsed by jsonEncode after decode.
      expect(
        CellEditor.parseValue(policy, '{"a": 1, "b":2}'),
        '{"a":1,"b":2}',
      );
    });

    test('json rejects invalid JSON', () {
      final policy = _policy(type: PgType.json, typeName: 'json');
      expect(
        () => CellEditor.parseValue(policy, 'not json'),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown text type keeps the string verbatim', () {
      expect(
        CellEditor.parseValue(_policy(), 'hello'),
        'hello',
      );
    });

    test(
      'non-string raw value goes through .toString() for non-text types',
      () {
        final policy = _policy(type: PgType.int4, typeName: 'int4');
        expect(CellEditor.parseValue(policy, 42), 42);
      },
    );
  });
}
