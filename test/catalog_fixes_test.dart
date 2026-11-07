// Contract for the catalog and table-load fixes from BUGS.md (2026-11-07):
// * SQLite: tables named `sqlite` + one more character are listed (only the
//   literal `sqlite_` prefix is reserved); an INTEGER PRIMARY KEY on a rowid
//   table reports isIdentity, other keys do not; partial indexes do not make
//   a column "indexed".
// * Postgres: the CHECK-definition lookup is scoped to the failing table,
//   and the indexed-columns query reads key columns of non-partial indexes
//   only (no INCLUDE payload). Pinned by SQL text, as there is no live DB.
// * The tenant and soft-delete filters are decided from the table's real
//   columns, so hiding the column from a viewer never drops the filter
//   (checked end to end through TableLoader with a `none` grant).
// * LatestRequest: only the newest ticket is current.

import 'dart:io';

import 'package:dbscope/catalog/schema_catalog.dart';
import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/sqlite_executor.dart';
import 'package:dbscope/meta/meta_cache.dart';
import 'package:dbscope/meta/meta_settings.dart';
import 'package:dbscope/navigator/latest_request.dart';
import 'package:dbscope/query/runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import 'support/fake_executor.dart';

void main() {
  late sq.Database db;
  late SqliteExecutor executor;

  setUp(() {
    db = sq.sqlite3.openInMemory();
    executor = SqliteExecutor(db);
  });
  tearDown(() => executor.close());

  group('SQLite catalog', () {
    test('lists tables that merely start with sqlite, hides sqlite_ ones', () async {
      db.execute('CREATE TABLE sqlite3_meta (id INTEGER)');
      db.execute('CREATE TABLE sqlitex (id INTEGER)');
      db.execute('CREATE TABLE seq_user (id INTEGER PRIMARY KEY AUTOINCREMENT)');
      final tables = await SchemaCatalog(executor).listTables('main');
      final names = tables.map((table) => table.name).toSet();
      expect(names, containsAll(['sqlite3_meta', 'sqlitex', 'seq_user']));
      expect(names, isNot(contains('sqlite_sequence')));
    });

    test('INTEGER PRIMARY KEY is identity; other keys are not', () async {
      db.execute('CREATE TABLE a (id INTEGER PRIMARY KEY, n TEXT)');
      db.execute('CREATE TABLE b (id TEXT PRIMARY KEY, n TEXT)');
      db.execute('CREATE TABLE c (x INTEGER, y INTEGER, PRIMARY KEY (x, y))');
      db.execute('CREATE TABLE d (id INT PRIMARY KEY)');
      db.execute('CREATE TABLE e (id INTEGER PRIMARY KEY) WITHOUT ROWID');
      final catalog = SchemaCatalog(executor);
      Future<Set<String>> identities(String table) async => {
        for (final column in await catalog.listColumns('main', table))
          if (column.isIdentity) column.name,
      };
      expect(await identities('a'), {'id'});
      expect(await identities('b'), isEmpty);
      expect(await identities('c'), isEmpty);
      expect(await identities('d'), isEmpty);
      expect(await identities('e'), isEmpty);
    });

    test('a partial index does not make its column indexed', () async {
      db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b TEXT, c TEXT)');
      db.execute('CREATE INDEX t_a ON t (a)');
      db.execute('CREATE INDEX t_b_live ON t (b) WHERE c IS NULL');
      expect(await SchemaCatalog(executor).indexedColumns('main', 't'), {'a'});
    });
  });

  group('Postgres catalog SQL', () {
    test('the CHECK lookup is scoped to the failing table', () async {
      final fake = FakeDbExecutor();
      await SchemaCatalog(fake).lookupCheckDefinition(
        schema: 'public',
        table: 'orders',
        constraintName: 'qty_check',
      );
      final call = fake.calls.single;
      expect(call.sql, contains('con.conrelid'));
      expect(call.named, {'name': 'qty_check', 'schema': 'public', 'table': 'orders'});
    });

    test('indexed columns exclude INCLUDE payload and partial indexes', () async {
      final fake = FakeDbExecutor();
      await SchemaCatalog(fake).indexedColumns('public', 'orders');
      final sql = fake.calls.single.sql;
      expect(sql, contains('indnkeyatts'));
      expect(sql, contains('indpred IS NULL'));
    });
  });

  group('tenant and soft-delete filters', () {
    test('apply from the real column list, not the access-filtered one', () {
      final composed = composeBaseWhere(
        profile: ConnectionProfile(
          id: 'p',
          name: 'p',
          tenantFilter: const TenantFilter(column: 'account_id', value: 7),
        ),
        metaSoftDelete: 'deleted_at',
        defaultFilter: null,
        schema: 'main',
        table: 'items',
        tableColumnNames: {'id', 'account_id', 'deleted_at'},
        showDeleted: false,
        callerWhere: null,
        callerParams: const [],
      );
      expect(composed.where, r'"account_id" = $1 AND "deleted_at" IS NULL');
      expect(composed.params, [7]);
      expect(composed.tenantFilterApplied, isTrue);
      expect(composed.effectiveSoftDeleteColumn, 'deleted_at');
    });

    test('TableLoader still filters by a column the viewer cannot see', () async {
      db.execute(
        'CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, account_id INTEGER)',
      );
      db.execute("INSERT INTO items (name, account_id) VALUES ('mine', 1), ('theirs', 2)");
      final dir = Directory.systemTemp.createTempSync('dbscope_meta_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sidecar = File('${dir.path}/meta.yaml')
        ..writeAsStringSync('''
rbac: { default: read }
roles:
  - { id: everyone, label: Everyone }
grants:
  - { id: g1, role: everyone, target: "*.*.account_id", level: none }
''');
      final profile = ConnectionProfile(
        id: 'tenant-test',
        name: 'tenant test',
        readOnly: true,
        tenantFilter: const TenantFilter(column: 'account_id', value: 1),
        metadata: MetadataSettings(sidecarPath: sidecar.path),
      );
      await MetadataCache.instance.load(profile, executor);
      addTearDown(() => MetadataCache.instance.invalidate(profile.id));

      final catalog = SchemaCatalog(executor);
      expect(
        (await catalog.listColumns('main', 'items')).map((column) => column.name),
        isNot(contains('account_id')),
        reason: 'the column must really be hidden for this test to mean anything',
      );

      final loaded = await TableLoader(executor).loadTable(
        schema: 'main',
        table: 'items',
        profile: profile,
      );
      expect(loaded.tenantFilterApplied, isTrue);
      final names = loaded.firstRows.map((row) => row[loaded.columns.indexWhere((c) => c.name == 'name')]);
      expect(names, ['mine']);
    });
  });

  group('LatestRequest', () {
    test('only the newest ticket is current', () {
      final requests = LatestRequest();
      final first = requests.begin();
      expect(requests.isCurrent(first), isTrue);
      final second = requests.begin();
      expect(requests.isCurrent(first), isFalse);
      expect(requests.isCurrent(second), isTrue);
    });
  });
}
