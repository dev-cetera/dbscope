// Contract: metadata sources merge and resolve as plan.md "Sources"
// describes.
//
// - Same id in a higher source replaces the lower one; `enabled: false`
//   in a higher source removes the id.
// - Scalar kinds merge field by field: least specific first, then source
//   precedence, so the most specific rule wins and ties go to the higher
//   source.
// - A table's description never becomes its columns' description; a
//   sensitive table makes its columns sensitive.
// - The file format accepts inline specs, `rbac:` shorthand, and reports
//   (never throws on) bad rows.
// - List kinds parse into typed specs; bad ones become problems.

import 'dart:io';

import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/meta/meta_index.dart';
import 'package:dbscope/meta/meta_models.dart';
import 'package:dbscope/meta/meta_parse.dart';
import 'package:dbscope/meta/meta_sources.dart';
import 'package:flutter_test/flutter_test.dart';

MetaSourceData dbSource(List<Map<String, Object?>> rows) {
  final builder = MetaSourceBuilder(MetaSourceKind.database);
  for (final row in rows) {
    builder.addMetaEntry(row, where: 'db');
  }
  return builder.build();
}

void main() {
  test('higher source replaces same id; enabled:false removes it', () {
    final db = dbSource([
      {
        'id': 'a',
        'target': 'public.t',
        'kind': 'describe',
        'spec': '{"description":"db"}',
      },
      {
        'id': 'b',
        'target': 'public.t.c',
        'kind': 'describe',
        'spec': {'description': 'gone'},
      },
    ]);
    final file = FileSource.parseText('''
meta:
  - { id: a, target: public.t, kind: describe, description: file }
  - { id: b, kind: describe, enabled: false }
''');
    final index = MetaIndex.build(mergeMetaSources([file, db]));
    expect(index.describeTable('public', 't').description, 'file');
    expect(index.describeColumn('public', 't', 'c').description, isNull);
  });

  test('most specific wins, then source precedence', () {
    final db = dbSource([
      {
        'id': 'specific',
        'target': 'public.users.email',
        'kind': 'describe',
        'spec': {'description': 'specific from db'},
      },
    ]);
    final file = FileSource.parseText('''
meta:
  - { id: general, target: "*.*.email", kind: describe, description: general from file, unit: text }
''');
    final index = MetaIndex.build(mergeMetaSources([db, file]));
    final description = index.describeColumn('public', 'users', 'email');
    expect(description.description, 'specific from db');
    expect(
      description.unit,
      'text',
    ); // field-by-field: the general row still fills gaps
  });

  test("a table's description does not leak onto its columns", () {
    final file = FileSource.parseText('''
meta:
  - { id: t, target: public.items, kind: describe, description: Items }
  - { id: s, target: public.leads, kind: sensitive, excludeFromAi: true }
''');
    final index = MetaIndex.build(mergeMetaSources([file]));
    expect(index.describeColumn('public', 'items', 'name').description, isNull);
    expect(index.describeTable('public', 'items').description, 'Items');
    expect(
      index.sensitiveColumn('public', 'leads', 'email').excludeFromAi,
      isTrue,
    );
  });

  test('display: table-level and column-level resolve separately', () {
    final file = FileSource.parseText('''
meta:
  - { id: d1, target: "public.*", kind: display, defaultSort: "-created_at" }
  - { id: d2, target: public.users, kind: display, rowLabel: "{name}" }
  - { id: d3, target: "*.*.duration_ms", kind: display, renderer: duration }
''');
    final index = MetaIndex.build(mergeMetaSources([file]));
    final table = index.displayTable('public', 'users');
    expect(table.rowLabel, '{name}');
    expect(table.parsedDefaultSort, (column: 'created_at', descending: true));
    expect(
      index.displayColumn('public', 'runs', 'duration_ms').renderer,
      ValueRenderer.duration,
    );
    expect(index.displayColumn('public', 'users', 'name').renderer, isNull);
  });

  test('profile overrides sit on top', () {
    final file = FileSource.parseText('''
meta:
  - { id: p, target: "public.*", kind: policy, softDelete: deleted_at }
''');
    final profileRows = ProfileOverrideSource.fromProfile(
      ConnectionProfile(
        id: 'p',
        name: 'p',
        tableOverrides: const {
          'public.items': TableOverrides(softDeleteColumn: 'removed_at'),
        },
      ),
    );
    final index = MetaIndex.build(mergeMetaSources([file, profileRows]));
    // The machine's override beats the file for its table only.
    expect(index.policyTable('public', 'items').softDelete, 'removed_at');
    expect(index.policyTable('public', 'notes').softDelete, 'deleted_at');
  });

  test('an including file can disable a row its include defines', () async {
    final directory = await Directory.systemTemp.createTemp('dbscope_meta_');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/base.yaml').writeAsString('''
meta:
  - { id: q.keep, kind: query, label: Keep, sql: SELECT 1 }
  - { id: q.drop, kind: query, label: Drop, sql: SELECT 2 }
''');
    final top = File('${directory.path}/top.yaml');
    await top.writeAsString('''
include: [base.yaml]
meta:
  - { id: q.drop, enabled: false }
''');
    final index = MetaIndex.build(
      mergeMetaSources([await FileSource.load(top.path)]),
    );
    expect([for (final query in index.queries) query.id], ['q.keep']);
  });

  test('list kinds parse; bad entries become problems', () {
    final file = FileSource.parseText('''
meta:
  - { id: q1, kind: query, label: Overdue, sql: "SELECT 1 AS x" }
  - { id: q2, kind: query, label: Broken }
  - { id: a1, target: public.users, kind: action, label: Items, scope: row, run: query, sql: "SELECT * FROM items WHERE creator_user_id = @row_id" }
  - { id: a2, target: public.users, kind: action, label: Bad }
  - { id: c1, target: public.accounts, kind: chart, type: line, x: created_at, bucket: day }
  - { id: c2, kind: chart, type: nonsense }
  - { id: l1, target: "*.*.entity_id", kind: link, polymorphic: { by: entity_kind, table: lower } }
  - { id: k1, target: public.items, kind: check, label: Orphans, sql: "SELECT 1 WHERE false" }
  - { id: x1, kind: mystery }
''');
    final index = MetaIndex.build(mergeMetaSources([file]));
    expect(index.queries.map((query) => query.id), ['q1']);
    expect(
      index.actionsForTable(ActionScope.row, 'public', 'users').map((action) => action.id),
      ['a1'],
    );
    expect(
      index.chartsForTable('public', 'accounts').map((chart) => chart.id),
      [
        'c1',
      ],
    );
    expect(
      index.linksForColumn('public', 'assets', 'entity_id').single.polymorphicTable,
      TableNameTransform.lower,
    );
    expect(index.checks.single.label, 'Orphans');
    final messages = index.allProblems.map((problem) => problem.where).toList();
    expect(messages, containsAll(['q2', 'a2', 'c2', 'x1']));
  });

  test('the file format reports bad YAML instead of throwing', () {
    final data = FileSource.parseText('meta: [ {', where: 'bad.yaml');
    expect(data.problems.single.where, 'bad.yaml');
  });

  test('rbac shorthand creates the settings row', () {
    final index = MetaIndex.build(
      mergeMetaSources([
        FileSource.parseText('rbac: { default: none, identity: claimed }'),
      ]),
    );
    expect(index.rbac.defaultLevel, AccessLevel.none);
    expect(index.rbac.identity, IdentityMode.claimed);
    expect(index.document.hasAccessControl, isTrue);
  });

  test('newer format versions load with a problem', () {
    final index = MetaIndex.build(
      mergeMetaSources([
        FileSource.parseText('format: 99'),
      ]),
    );
    expect(index.allProblems.single.message, contains('newer'));
  });

  test('database spec cells decode from text or maps', () {
    expect(decodeSpecCell('{"a": 1}'), {'a': 1});
    expect(decodeSpecCell({'a': 1}), {'a': 1});
    expect(decodeSpecCell(null), isEmpty);
    expect(decodeStringListCell('["x","y"]'), ['x', 'y']);
  });
}
