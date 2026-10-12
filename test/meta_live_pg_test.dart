// Live integration test: schema metadata against a real Postgres that has
// the `dbscope` metadata tables loaded. Skipped unless DBSCOPE_LIVE_PG is
// set, so the normal suite never needs a database:
//
//   DBSCOPE_LIVE_PG=1 PGHOST=localhost PGUSER=user PGDATABASE=compledo \
//     DBSCOPE_LIVE_IDENTITY=you@example.com \
//     fvm flutter test test/meta_live_pg_test.dart
//
// Contract, generic (any project):
// - the tables are detected and loaded (outcome `loaded`, no problems);
// - every named query, check, SQL chart and table chart runs, fenced
//   read-only, without a database error;
// - every action's SQL/filter is valid SQL against the real schema
//   (prepared via EXPLAIN in a read-only transaction, with the row
//   placeholders bound to NULL);
// - catalog filtering hides `none` columns and the pager never selects them.

import 'dart:io';

import 'package:dbscope/catalog/schema_catalog.dart';
import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/postgres_executor.dart';
import 'package:dbscope/db/postgres_plugin.dart';
import 'package:dbscope/meta/action_binding.dart';
import 'package:dbscope/meta/charts/chart_data.dart';
import 'package:dbscope/meta/meta_cache.dart';
import 'package:dbscope/meta/meta_models.dart';
import 'package:dbscope/meta/meta_settings.dart';
import 'package:dbscope/meta/meta_sources.dart';
import 'package:dbscope/meta/native_facts.dart';
import 'package:dbscope/meta/read_only_exec.dart';
import 'package:flutter_test/flutter_test.dart';

String _env(String key, String fallback) =>
    Platform.environment[key] ?? fallback;

void main() {
  final enabled = Platform.environment['DBSCOPE_LIVE_PG'] != null;

  group('live Postgres metadata', skip: !enabled, () {
    late PostgresExecutor executor;
    late ConnectionProfile profile;

    setUpAll(() async {
      final conn = await PostgresKindPlugin.openConnection(
        host: _env('PGHOST', 'localhost'),
        port: int.parse(_env('PGPORT', '5432')),
        database: _env('PGDATABASE', 'postgres'),
        username: _env('PGUSER', 'postgres'),
        password: _env('PGPASSWORD', ''),
      );
      executor = PostgresExecutor(conn);
      profile = ConnectionProfile(
        id: 'live-test',
        name: 'live test',
        metadata: MetadataSettings(
          claimedIdentity: Platform.environment['DBSCOPE_LIVE_IDENTITY'],
        ),
      );
      await MetadataCache.instance.load(profile, executor);
    });

    tearDownAll(() async {
      await executor.close();
    });

    MetaSnapshot snapshot() => MetadataCache.instance.snapshotFor(profile.id)!;

    test('metadata tables load without problems', () {
      final s = snapshot();
      expect(s.tablesOutcome, MetaTablesOutcome.loaded);
      expect(s.problems, isEmpty, reason: s.problems.join('\n'));
      expect(s.index.document.rows, isNotEmpty);
    });

    test('every named query runs read-only', () async {
      for (final q in snapshot().index.queries) {
        final bound = bindSql(
          q.sql,
          BindingContext(inputs: {for (final i in q.inputs) i.name: null}),
        );
        await executeReadOnly(
          executor,
          'SELECT * FROM (${bound.sql}) AS q LIMIT 1',
          named: bound.named,
        ).catchError((Object e) => fail('query ${q.id}: $e'));
      }
    });

    test('every check runs read-only', () async {
      for (final c in snapshot().index.checks) {
        await executeReadOnly(
          executor,
          'SELECT count(*) FROM (${c.sql}) AS dbscope_check',
        ).catchError((Object e) => fail('check ${c.id}: $e'));
      }
    });

    test('every chart runs', () async {
      for (final c in snapshot().index.charts) {
        final placeholders = c.source is ChartSqlSource
            ? findPlaceholders((c.source as ChartSqlSource).sql)
            : const <String>[];
        final row = {
          for (final p in placeholders)
            if (p.startsWith('row_')) p.substring(4): null,
        };
        await runChart(
          c,
          executor: executor,
          row: BindingContext(row: row),
        ).catchError((Object e) => fail('chart ${c.id}: $e'));
      }
    });

    test('every action is valid SQL against the schema', () async {
      for (final a in snapshot().index.actions) {
        final text = a.sql ?? a.filter;
        if (text == null) continue;
        // Bind every placeholder to NULL; EXPLAIN proves the statement
        // parses and resolves without running it.
        final names = findPlaceholders(text);
        final named = {for (final n in names) n: null};
        final table = a.table?.exactTable ?? a.target.exactTable;
        final sql = a.sql != null
            ? 'EXPLAIN $text'
            : 'EXPLAIN SELECT 1 FROM "${table!.schema}"."${table.table}" '
                  'WHERE $text';
        await executeReadOnly(
          executor,
          sql,
          named: named,
        ).catchError((Object e) => fail('action ${a.id}: $e'));
      }
    });

    test('native facts load for every table and its first column', () async {
      final catalog = SchemaCatalog.unfiltered(executor);
      var withComment = 0;
      for (final s in await catalog.listSchemas()) {
        if (s.isSystem) continue;
        for (final t in await catalog.listTables(s.name)) {
          final tableFacts = await loadTableFacts(
            executor,
            schema: t.schema,
            table: t.name,
          );
          expect(tableFacts.attributes, isNotEmpty, reason: t.name);
          final columns = await catalog.listColumns(t.schema, t.name);
          for (final c in columns) {
            final facts = await loadColumnFacts(
              executor,
              schema: t.schema,
              table: t.name,
              column: c.name,
            );
            if (facts.comment != null) withComment++;
          }
        }
      }
      // A diagnostic count for whoever runs this live-DB test by hand.
      // ignore: avoid_print
      print('columns with a native COMMENT: $withComment');
    });

    test('hidden columns are never listed or selected', () async {
      final policy = snapshot().policy;
      if (!policy.active) return;
      final catalog = SchemaCatalog(executor);
      for (final s in await SchemaCatalog.unfiltered(executor).listSchemas()) {
        if (s.isSystem) continue;
        for (final t in await SchemaCatalog.unfiltered(
          executor,
        ).listTables(s.name)) {
          final all = await SchemaCatalog.unfiltered(
            executor,
          ).listColumns(t.schema, t.name);
          final visible = {
            for (final c in await catalog.listColumns(t.schema, t.name)) c.name,
          };
          for (final c in all) {
            final decision = policy.forColumn(t.schema, t.name, c.name);
            if (decision.isNone) {
              expect(
                visible.contains(c.name),
                // Primary keys stay (masked) by design.
                (await catalog.primaryKey(t.schema, t.name)).contains(c.name),
                reason: '${t.schema}.${t.name}.${c.name}',
              );
            }
          }
        }
      }
    });
  });
}
