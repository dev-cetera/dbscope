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

String _env(String key, String fallback) => Platform.environment[key] ?? fallback;

void main() {
  final enabled = Platform.environment['DBSCOPE_LIVE_PG'] != null;

  group('live Postgres metadata', skip: !enabled, () {
    late PostgresExecutor executor;
    late ConnectionProfile profile;

    setUpAll(() async {
      final connection = await PostgresKindPlugin.openConnection(
        host: _env('PGHOST', 'localhost'),
        port: int.parse(_env('PGPORT', '5432')),
        database: _env('PGDATABASE', 'postgres'),
        username: _env('PGUSER', 'postgres'),
        password: _env('PGPASSWORD', ''),
      );
      executor = PostgresExecutor(connection);
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
      final metaSnapshot = snapshot();
      expect(metaSnapshot.tablesOutcome, MetaTablesOutcome.loaded);
      expect(
        metaSnapshot.problems,
        isEmpty,
        reason: metaSnapshot.problems.join('\n'),
      );
      expect(metaSnapshot.index.document.rows, isNotEmpty);
    });

    test('every named query runs read-only', () async {
      for (final query in snapshot().index.queries) {
        final bound = bindSql(
          query.sql,
          BindingContext(inputs: {for (final i in query.inputs) i.name: null}),
        );
        await executeReadOnly(
          executor,
          'SELECT * FROM (${bound.sql}) AS q LIMIT 1',
          named: bound.named,
        ).catchError((Object e) => fail('query ${query.id}: $e'));
      }
    });

    test('every check runs read-only', () async {
      for (final check in snapshot().index.checks) {
        await executeReadOnly(
          executor,
          'SELECT count(*) FROM (${check.sql}) AS dbscope_check',
        ).catchError((Object e) => fail('check ${check.id}: $e'));
      }
    });

    test('every chart runs', () async {
      for (final chart in snapshot().index.charts) {
        final placeholders = chart.source is ChartSqlSource
            ? findPlaceholders((chart.source as ChartSqlSource).sql)
            : const <String>[];
        final row = {
          for (final placeholder in placeholders)
            if (placeholder.startsWith('row_')) placeholder.substring(4): null,
        };
        await runChart(
          chart,
          executor: executor,
          row: BindingContext(row: row),
        ).catchError((Object e) => fail('chart ${chart.id}: $e'));
      }
    });

    test('every action is valid SQL against the schema', () async {
      for (final action in snapshot().index.actions) {
        final text = action.sql ?? action.filter;
        if (text == null) continue;
        // Bind every placeholder to NULL; EXPLAIN proves the statement
        // parses and resolves without running it.
        final names = findPlaceholders(text);
        final named = {for (final name in names) name: null};
        final table = action.table?.exactTable ?? action.target.exactTable;
        final sql = action.sql != null
            ? 'EXPLAIN $text'
            : 'EXPLAIN SELECT 1 FROM "${table!.schema}"."${table.table}" '
                  'WHERE $text';
        await executeReadOnly(
          executor,
          sql,
          named: named,
        ).catchError((Object e) => fail('action ${action.id}: $e'));
      }
    });

    test('native facts load for every table and its first column', () async {
      final catalog = SchemaCatalog.unfiltered(executor);
      var withComment = 0;
      for (final schema in await catalog.listSchemas()) {
        if (schema.isSystem) continue;
        for (final table in await catalog.listTables(schema.name)) {
          final tableFacts = await loadTableFacts(
            executor,
            schema: table.schema,
            table: table.name,
          );
          expect(tableFacts.attributes, isNotEmpty, reason: table.name);
          final columns = await catalog.listColumns(table.schema, table.name);
          for (final column in columns) {
            final facts = await loadColumnFacts(
              executor,
              schema: table.schema,
              table: table.name,
              column: column.name,
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
      for (final schema in await SchemaCatalog.unfiltered(
        executor,
      ).listSchemas()) {
        if (schema.isSystem) continue;
        for (final table in await SchemaCatalog.unfiltered(
          executor,
        ).listTables(schema.name)) {
          final all = await SchemaCatalog.unfiltered(
            executor,
          ).listColumns(table.schema, table.name);
          final visible = {
            for (final column in await catalog.listColumns(
              table.schema,
              table.name,
            ))
              column.name,
          };
          for (final column in all) {
            final decision = policy.forColumn(
              table.schema,
              table.name,
              column.name,
            );
            if (decision.isNone) {
              expect(
                visible.contains(column.name),
                // Primary keys stay (masked) by design.
                (await catalog.primaryKey(
                  table.schema,
                  table.name,
                )).contains(column.name),
                reason: '${table.schema}.${table.name}.${column.name}',
              );
            }
          }
        }
      }
    });
  });
}
