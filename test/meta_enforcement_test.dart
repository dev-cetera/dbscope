// Contract: the data-path pieces of schema metadata.
//
// - Masked columns are selected as NULL (values never leave the database)
//   and shown as MaskedValue; masked primary keys are still fetched for
//   the keyset cursor, then masked.
// - Metadata SQL runs fenced: BEGIN TRANSACTION READ ONLY … COMMIT on a
//   transactional backend (ROLLBACK on error), unfenced only where the
//   backend can't do transactions.
// - toPositional rewrites @names to $n for the pager's baseWhere slot.
// - The enforcement plan never grants SELECT on masked/none columns,
//   grants per-column SELECT when any column is hidden, and records
//   expectations for drift.
// - Trust covers every SQL-bearing item; changing one invalidates trust.
// - Renderers format values; masked values never format.

import 'package:dbscope/catalog/pg_type.dart';
import 'package:dbscope/catalog/schema_catalog.dart';
import 'package:dbscope/db/executor.dart';
import 'package:dbscope/meta/action_binding.dart';
import 'package:dbscope/meta/enforcement_sql.dart';
import 'package:dbscope/meta/masked_value.dart';
import 'package:dbscope/meta/meta_index.dart';
import 'package:dbscope/meta/meta_models.dart';
import 'package:dbscope/meta/meta_sources.dart';
import 'package:dbscope/meta/meta_writer.dart';
import 'package:dbscope/meta/read_only_exec.dart';
import 'package:dbscope/meta/ui/action_trust.dart';
import 'package:dbscope/meta/value_format.dart';
import 'package:dbscope/query/cancel_token.dart';
import 'package:dbscope/query/pager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_executor.dart';

ColumnInfo _col(String name, {AccessLevel level = AccessLevel.full}) =>
    ColumnInfo(
      name: name,
      type: PgType.text,
      typeName: 'text',
      nullable: true,
      defaultExpr: null,
      isGenerated: false,
      isIdentity: false,
      accessLevel: level,
    );

class _NoTxExecutor extends FakeDbExecutor {
  @override
  DbCapabilities get capabilities => const DbCapabilities(dml: true);
}

void main() {
  group('pager masking', () {
    test('masked non-key columns are selected as NULL and masked', () async {
      final executor = FakeDbExecutor();
      executor.enqueue(
        const DbResult(
          columns: [],
          rows: [
            [1, null, 'Ann'],
          ],
        ),
      );
      final pager = KeysetPager(
        conn: executor,
        schema: 'public',
        table: 'users',
        columns: [
          _col('id'),
          _col('email', level: AccessLevel.masked),
          _col('name'),
        ],
        pkColumns: const ['id'],
      );
      final page = await pager.fetchNext();
      expect(executor.calls.single.sql, contains('NULL AS "email"'));
      expect(page.rows.single[1], isA<MaskedValue>());
      expect(page.rows.single[2], 'Ann');
    });

    test(
      'a masked primary key is fetched for the cursor, then masked',
      () async {
        final executor = FakeDbExecutor();
        executor.enqueue(
          const DbResult(
            columns: [],
            rows: [
              [42, 'x'],
            ],
          ),
        );
        final pager = KeysetPager(
          conn: executor,
          schema: 'public',
          table: 't',
          columns: [
            _col('id', level: AccessLevel.masked),
            _col('v'),
          ],
          pkColumns: const ['id'],
          pageSize: 1,
        );
        final page = await pager.fetchNext();
        expect(executor.calls.single.sql, isNot(contains('NULL AS "id"')));
        expect(page.rows.single.first, isA<MaskedValue>());
        expect(page.lastPkVals, [42]);
      },
    );
  });

  group('executeReadOnly', () {
    test('checks for an open transaction, then fences read-only', () async {
      final executor = FakeDbExecutor();
      await executeReadOnly(
        executor,
        'SELECT 1',
        timeout: const Duration(seconds: 2),
      );
      final sql = [for (final call in executor.calls) call.sql];
      expect(sql[0], contains('set_config'));
      expect(sql[1], contains('current_setting'));
      expect(sql.skip(2), [
        'BEGIN TRANSACTION READ ONLY',
        'SET LOCAL statement_timeout = 2000',
        'SELECT 1',
        'COMMIT',
      ]);
    });

    test('refuses when a transaction is already open', () async {
      // The probe's setting survived into the next statement.
      final executor = FakeDbExecutor()
        ..enqueue(const DbResult(columns: [], rows: []))
        ..enqueueRow(const [true], columns: const ['open']);
      await expectLater(
        executeReadOnly(executor, 'SELECT 1'),
        throwsA(isA<MetaSessionBusy>()),
      );
      // Never BEGINs: a nested BEGIN would be a no-op, and our COMMIT
      // would commit the user's open work.
      expect(executor.calls, hasLength(2));
    });

    test('fenced statements on one executor never interleave', () async {
      final executor = FakeDbExecutor();
      await Future.wait([
        executeReadOnly(executor, 'SELECT 1'),
        executeReadOnly(executor, 'SELECT 2'),
      ]);
      final sql = [
        for (final call in executor.calls)
          if (!call.sql.contains('dbscope.xact_probe')) call.sql,
      ];
      expect(sql, [
        'BEGIN TRANSACTION READ ONLY',
        'SELECT 1',
        'COMMIT',
        'BEGIN TRANSACTION READ ONLY',
        'SELECT 2',
        'COMMIT',
      ]);
    });

    test('rolls back when the statement fails', () async {
      final executor = _ThrowingExecutor();
      await expectLater(
        executeReadOnly(executor, 'SELECT boom'),
        throwsA(isA<StateError>()),
      );
      expect(executor.calls.last.sql, 'ROLLBACK');
    });

    test('runs unfenced where transactions are unsupported', () async {
      final executor = _NoTxExecutor();
      await executeReadOnly(executor, 'SELECT 1');
      expect([for (final call in executor.calls) call.sql], ['SELECT 1']);
    });
  });

  test('toPositional numbers placeholders and keeps annotations as casts', () {
    final bound = bindSql(
      'a = @input_x AND b = @row_id:int8 AND c = @input_x',
      const BindingContext(inputs: {'x': 'v'}, row: {'id': 9}),
    );
    final positional = toPositional(bound);
    expect(positional.sql, r'a = $1 AND b = $2::int8 AND c = $1');
    expect(positional.params, ['v', 9]);
  });

  test('placeholders inside string literals stay literal text', () {
    final bound = bindSql(
      r"a = 'x@row_id' AND b = E'it\'s @row_id' AND c = @row_id",
      const BindingContext(row: {'id': 9}),
    );
    final positional = toPositional(bound);
    expect(
      positional.sql,
      r"a = 'x@row_id' AND b = E'it\'s @row_id' AND c = $1",
    );
    expect(positional.params, [9]);
  });

  test('splitStatements ignores semicolons in strings and comments', () {
    expect(
      splitStatements("CREATE x; -- a; b\nINSERT 'a;b'; SELECT 1"),
      ['CREATE x', "INSERT 'a;b'", 'SELECT 1'],
    );
  });

  group('enforcement plan', () {
    MetaDocument metaDocument() => mergeMetaSources([
      FileSource.parseText('''
rbac: { default: read }
roles:
  - { id: support, db_role: support_team }
  - { id: nologin }
grants:
  - { id: e1, role: everyone, target: "*.*.password_hash", level: none }
  - { id: e2, role: everyone, target: "*.*.email", level: masked }
  - { id: s1, role: support, target: "public.notes", level: full }
  - { id: s2, role: support, target: "public.secrets", level: none }
'''),
    ]);

    const tables = [
      EnforcementTable(
        schema: 'public',
        table: 'users',
        columns: ['id', 'email', 'password_hash', 'name'],
        primaryKey: ['id'],
      ),
      EnforcementTable(
        schema: 'public',
        table: 'notes',
        columns: ['id', 'body'],
        primaryKey: ['id'],
      ),
      EnforcementTable(
        schema: 'public',
        table: 'secrets',
        columns: ['id'],
        primaryKey: ['id'],
      ),
    ];

    test('per-column SELECT when columns are hidden; full grants DML', () {
      final document = metaDocument();
      final plan = buildEnforcementPlan(
        document: document,
        settings: MetaIndex.build(document).rbac,
        tables: tables,
      );
      final script = plan.script;
      expect(
        script,
        contains(
          'GRANT SELECT ("id", "name") ON "public"."users" TO "support_team";',
        ),
      );
      expect(
        script,
        contains('GRANT SELECT ON "public"."notes" TO "support_team";'),
      );
      expect(
        script,
        contains('GRANT INSERT, DELETE ON "public"."notes" TO "support_team";'),
      );
      expect(script, isNot(contains('"public"."secrets" TO')));
      expect(plan.notes.single, contains('nologin'));
      final emailSelect = plan.expectations.firstWhere(
        (e) => e.column == 'email' && e.privilege == Privilege.select,
      );
      expect(emailSelect.granted, isFalse);
    });

    test('views get SELECT only; inserts get the schema sequences', () {
      final document = metaDocument();
      final script = buildEnforcementPlan(
        document: document,
        settings: MetaIndex.build(document).rbac,
        tables: [
          ...tables,
          const EnforcementTable(
            schema: 'public',
            table: 'notes_view',
            columns: ['id', 'body'],
            isView: true,
          ),
        ],
      ).script;
      expect(
        script,
        contains('GRANT SELECT ON "public"."notes_view" TO "support_team";'),
      );
      expect(script, isNot(contains('UPDATE ON "public"."notes_view"')));
      expect(
        script,
        isNot(contains('INSERT, DELETE ON "public"."notes_view"')),
      );
      expect(
        script,
        contains(
          'GRANT USAGE ON ALL SEQUENCES IN SCHEMA "public" TO "support_team";',
        ),
      );
    });

    test('roles sharing a db_role get one block with their union', () {
      final document = mergeMetaSources([
        FileSource.parseText('''
rbac: { default: none }
roles:
  - { id: a, db_role: staff }
  - { id: b, db_role: staff }
grants:
  - { id: g1, role: a, target: "public.notes", level: read }
  - { id: g2, role: b, target: "public.users", level: read }
'''),
      ]);
      final script = buildEnforcementPlan(
        document: document,
        settings: MetaIndex.build(document).rbac,
        tables: tables,
      ).script;
      // One REVOKE per table — a second block would revoke the first's
      // grants.
      expect(
        'REVOKE ALL ON "public"."notes" FROM "staff";'
            .allMatches(script)
            .length,
        1,
      );
      expect(script, contains('GRANT SELECT ON "public"."notes" TO "staff";'));
      expect(script, contains('ON "public"."users" TO "staff";'));
    });
  });

  group('trust', () {
    MetaIndex index(String sql) => MetaIndex.build(
      mergeMetaSources([
        FileSource.parseText('''
meta:
  - { id: q, kind: query, label: Q, sql: "$sql" }
  - { id: a, target: public.t, kind: action, label: A, scope: row, run: exec, sql: "DELETE FROM t WHERE id = @row_id" }
  - { id: d, target: public.t, kind: display, defaultFilter: "x > 1" }
'''),
      ]),
    );

    test('read covers queries and default filters; exec covers writes', () {
      final read = trustItems(index('SELECT 1'), TrustScope.read);
      expect([for (final i in read) i.kind], ['default filter', 'query']);
      final execItems = trustItems(index('SELECT 1'), TrustScope.exec);
      expect([for (final i in execItems) i.id], ['a']);
    });

    test('any change to the SQL changes the hash', () {
      final before = MetaTrust.hashOf(
        trustItems(index('SELECT 1'), TrustScope.read),
      );
      final after = MetaTrust.hashOf(
        trustItems(index('SELECT 2'), TrustScope.read),
      );
      expect(before, isNot(after));
    });
  });

  group('renderers', () {
    test('format values; masked and null fall back', () {
      expect(
        formatForRenderer(ValueRenderer.money, {
          'currency': 'AUD',
          'minorUnits': true,
        }, 123456),
        '1,234.56 AUD',
      );
      expect(formatForRenderer(ValueRenderer.bytes, const {}, 1536), '1.5 KB');
      expect(
        formatForRenderer(ValueRenderer.duration, const {}, 125000),
        '2m 05s',
      );
      expect(
        formatForRenderer(ValueRenderer.timestamp, const {
          'utcOffset': '+10:00',
        }, DateTime.utc(2026, 10, 11, 23, 30)),
        '2026-10-12 09:30:00 +10:00',
      );
      expect(
        formatForRenderer(
          ValueRenderer.relativeTime,
          const {},
          DateTime.utc(2026, 10, 11, 9),
          now: DateTime.utc(2026, 10, 11, 12),
        ),
        '3 h ago',
      );
      expect(
        formatForRenderer(ValueRenderer.money, const {}, MaskedValue.instance),
        isNull,
      );
      expect(parseColorValue('#f00'), 0xFFFF0000);
      expect(
        renderRowLabel('{name} ({status})', {'name': 'Milk', 'status': 'OPEN'}),
        'Milk (OPEN)',
      );
    });
  });
}

class _ThrowingExecutor extends FakeDbExecutor {
  @override
  Future<DbResult> execute(
    String sql, {
    List<Object?>? positional,
    Map<String, Object?>? named,
    CancelToken? cancelToken,
  }) async {
    await super.execute(sql, positional: positional, named: named);
    if (sql.contains('boom')) throw StateError('boom');
    return const DbResult(columns: [], rows: []);
  }
}
