// Contract: plan.md "Access control" resolution, pinned with the plan's own
// worked example (revision 2). Revision 1 combined roles "per role, then
// most generous" and leaked password_hash to support; the first test here
// is the regression guard for that.
//
// - Most specific grant wins across ALL held roles (depth first, then
//   segment score); among equally specific grants the most generous wins.
// - No matching grant → the rbac default.
// - A `none` table makes every column `none`; PK columns floor at masked.
// - Claimed (`user:`) principals only count when identity allows them.
// - Unreadable rules fail closed: read-only, no capabilities.
// - dbscope's own tables are `none` without `manage`.
// - Postgres privileges cap the decision.

import 'package:dbscope/meta/access_policy.dart';
import 'package:dbscope/meta/meta_models.dart';
import 'package:dbscope/meta/meta_sources.dart';
import 'package:dbscope/meta/meta_settings.dart';
import 'package:flutter_test/flutter_test.dart';

MetaDocument worked() {
  final data = FileSource.parseText('''
rbac: { default: read, identity: either }
roles:
  - { id: everyone, label: Everyone }
  - { id: support, label: Support, capabilities: [export] }
  - { id: intern, label: Intern }
  - { id: engineer, label: Engineer, capabilities: [query, ai, exec] }
  - { id: admin, label: Admin, inherits: [engineer], capabilities: [manage] }
members:
  - { role: support, principal: "pg:support_team" }
  - { role: intern, principal: "user:sam@x.com" }
  - { role: engineer, principal: "pg:engineers" }
  - { role: admin, principal: "pg:alice" }
grants:
  - { id: e1, role: everyone, target: "*.*.password_hash", level: none }
  - { id: e2, role: everyone, target: "*.*.email", level: masked }
  - { id: e3, role: everyone, target: "*.*.*_internal", level: read, default_hidden: true }
  - { id: s1, role: support, target: "public.*", level: read }
  - { id: s2, role: support, target: "*.*.email", level: read }
  - { id: i1, role: intern, target: "public.billing", level: none }
  - { id: g1, role: engineer, target: "*.*", level: full }
  - { id: g2, role: engineer, target: "public.billing_events", level: read }
  - { id: a1, role: admin, target: "*.*.password_hash", level: read }
''');
  expect(data.problems, isEmpty);
  return mergeMetaSources([data]);
}

AccessPolicy policyFor(
  MetaDocument doc, {
  Set<String> pg = const {},
  String? claimed,
}) => AccessPolicy.resolve(
  document: doc,
  settings: const RbacSettings(),
  identity: AccessIdentity(postgresRoles: pg, claimedUser: claimed),
);

void main() {
  late MetaDocument doc;
  setUp(() => doc = worked());

  test('support never sees password_hash (revision-1 regression)', () {
    final p = policyFor(doc, pg: {'bob', 'support_team'});
    expect(
      p.forColumn('public', 'users', 'password_hash').level,
      AccessLevel.none,
    );
  });

  test('support: email read (tie, generous wins), internals hidden', () {
    final p = policyFor(doc, pg: {'bob', 'support_team'});
    expect(p.forColumn('public', 'users', 'email').level, AccessLevel.read);
    final internal = p.forColumn('public', 'users', 'notes_internal');
    expect(internal.level, AccessLevel.read);
    expect(internal.defaultHidden, isTrue);
    expect(p.forTable('public', 'users').level, AccessLevel.read);
    expect(p.can(Capability.export), isTrue);
    expect(p.can(Capability.query), isFalse);
  });

  test('intern who is also support: billing is none', () {
    final p = policyFor(doc, pg: {'support_team'}, claimed: 'Sam@X.com');
    expect(p.forTable('public', 'billing').level, AccessLevel.none);
    expect(p.forColumn('public', 'billing', 'amount').level, AccessLevel.none);
    expect(p.forTable('public', 'users').level, AccessLevel.read);
  });

  test('engineer: masked email, read billing_events, full elsewhere', () {
    final p = policyFor(doc, pg: {'eve', 'engineers'});
    expect(p.forColumn('public', 'users', 'email').level, AccessLevel.masked);
    expect(p.forTable('public', 'billing_events').level, AccessLevel.read);
    expect(p.forTable('public', 'users').level, AccessLevel.full);
    expect(p.forColumn('public', 'users', 'name').level, AccessLevel.full);
    expect(
      p.forColumn('public', 'users', 'notes_internal').level,
      AccessLevel.read,
    );
    expect(p.can(Capability.exec), isTrue);
    expect(p.can(Capability.manage), isFalse);
  });

  test('admin lifts password_hash with one equally specific row', () {
    final p = policyFor(doc, pg: {'alice'});
    expect(p.roleIds, containsAll(['admin', 'engineer', 'everyone']));
    expect(
      p.forColumn('public', 'users', 'password_hash').level,
      AccessLevel.read,
    );
    expect(p.can(Capability.manage), isTrue);
    expect(p.can(Capability.query), isTrue);
  });

  test('unlisted user gets the default, masked email, no hashes', () {
    final p = policyFor(doc, pg: {'mallory'});
    expect(p.forTable('public', 'orders').level, AccessLevel.read);
    expect(p.forColumn('public', 'users', 'email').level, AccessLevel.masked);
    expect(
      p.forColumn('public', 'users', 'password_hash').level,
      AccessLevel.none,
    );
    expect(p.can(Capability.export), isFalse);
  });

  test('primary keys floor at masked', () {
    final p = policyFor(doc, pg: {'mallory'});
    final d = p.forColumn(
      'public',
      'users',
      'password_hash',
      isPrimaryKey: true,
    );
    expect(d.level, AccessLevel.masked);
  });

  test('claimed identity ignored when identity is verified', () {
    final p = AccessPolicy.resolve(
      document: doc,
      settings: const RbacSettings(identity: IdentityMode.verified),
      identity: const AccessIdentity(claimedUser: 'sam@x.com'),
    );
    expect(p.roleIds, isNot(contains('intern')));
    expect(p.forTable('public', 'billing').level, AccessLevel.read);
  });

  test('no access control → unrestricted', () {
    final p = policyFor(MetaDocument.empty);
    expect(p.active, isFalse);
    expect(p.forTable('a', 'b').level, AccessLevel.full);
    expect(p.can(Capability.manage), isTrue);
  });

  test('fail closed: read-only and no capabilities', () {
    final p = AccessPolicy.failClosed('permission denied');
    expect(p.forTable('a', 'b').level, AccessLevel.read);
    expect(p.forColumn('a', 'b', 'c').level, AccessLevel.read);
    for (final c in Capability.values) {
      expect(p.can(c), isFalse, reason: c.name);
    }
  });

  test("dbscope's own tables need manage", () {
    bool isMeta(String schema, String table) => MetaTableNames.isMetaTable(
      schema,
      table,
      MetadataSettings.defaults,
      sqlite: false,
    );
    AccessPolicy resolve(Set<String> pg) => AccessPolicy.resolve(
      document: doc,
      settings: const RbacSettings(),
      identity: AccessIdentity(postgresRoles: pg),
      isMetaTable: isMeta,
    );
    expect(
      resolve({'mallory'}).forTable('dbscope', 'dbscope_access_grants').level,
      AccessLevel.none,
    );
    expect(
      resolve({'alice'}).forTable('dbscope', 'dbscope_access_grants').level,
      isNot(AccessLevel.none),
    );
  });

  test('metadata tables carry the dbscope_ prefix; app tables never match', () {
    bool isMeta(String schema, String table, {bool sqlite = false}) =>
        MetaTableNames.isMetaTable(
          schema,
          table,
          MetadataSettings.defaults,
          sqlite: sqlite,
        );
    expect(isMeta('dbscope', 'dbscope_metadata'), isTrue);
    expect(isMeta('dbscope', 'dbscope_access_roles'), isTrue);
    expect(isMeta('dbscope', 'dbscope_access_role_members'), isTrue);
    expect(isMeta('dbscope', 'dbscope_access_grants'), isTrue);
    // An application's own access-control tables are not ours, even in
    // the same schema.
    expect(isMeta('dbscope', 'roles'), isFalse);
    expect(isMeta('public', 'dbscope_access_roles'), isFalse);
    expect(isMeta('main', '_dbscope_access_grants', sqlite: true), isTrue);
    expect(isMeta('main', 'grants', sqlite: true), isFalse);
  });

  test('Postgres privileges cap the decision', () {
    final p = AccessPolicy.resolve(
      document: doc,
      settings: const RbacSettings(),
      identity: const AccessIdentity(postgresRoles: {'engineers'}),
      ceilings: PrivilegeCeilings(
        tables: {
          PrivilegeCeilings.tableKey('public', 'users'): (
            select: true,
            insert: false,
            update: false,
            delete: false,
          ),
        },
      ),
    );
    expect(p.forTable('public', 'users').level, AccessLevel.read);
    expect(p.forColumn('public', 'users', 'name').level, AccessLevel.read);
  });

  test('role inheritance cycles are reported, not fatal', () {
    final data = FileSource.parseText('''
roles:
  - { id: a, inherits: [b] }
  - { id: b, inherits: [a] }
members:
  - { role: a, principal: "*" }
grants:
  - { id: g, role: b, target: "*.*", level: full }
''');
    final p = policyFor(mergeMetaSources([data]));
    expect(p.problems, isNotEmpty);
    expect(p.forTable('x', 'y').level, AccessLevel.full);
  });

  test('named queries resolve through query: grants', () {
    final data = FileSource.parseText('''
roles: [{ id: analyst }]
members: [{ role: analyst, principal: "pg:ana" }]
grants:
  - { id: q0, role: everyone, target: "query:*", level: none }
  - { id: q1, role: analyst, target: "query:signups", level: read }
  - { id: q2, role: analyst, target: "query:signups.email", level: masked }
''');
    final p = policyFor(mergeMetaSources([data]), pg: {'ana'});
    expect(p.forQuery('signups').level, AccessLevel.read);
    expect(p.forQuery('other').level, AccessLevel.none);
    expect(p.forQueryColumn('signups', 'email').level, AccessLevel.masked);
    expect(p.forQueryColumn('signups', 'day').level, AccessLevel.read);
  });
}
