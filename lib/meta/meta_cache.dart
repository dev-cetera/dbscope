// MetadataCache — per-window, per-profile schema metadata, modelled on
// DbmlCache. Loaded in the background on connect, reloaded on reconnect,
// on "Reload metadata" (which also tells every other window via the bus),
// and when the profile's metadata settings change.
//
// The cache also remembers which executor belongs to which profile (an
// Expando), so code that only holds a DbExecutor — SchemaCatalog, the
// pager — can find the access policy without threading a profile id
// through every call site.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/profile.dart';
import '../db/executor.dart';
import 'access_policy.dart';
import 'meta_index.dart';
import 'meta_models.dart';
import 'meta_settings.dart';
import 'meta_sources.dart';

enum MetaLoadStatus { none, loading, ready }

/// Everything known about one connection's metadata at one moment.
class MetaSnapshot {
  const MetaSnapshot({
    required this.profileId,
    required this.status,
    required this.index,
    required this.policy,
    required this.tablesOutcome,
    required this.settings,
    required this.identity,
    required this.isSqlite,
    this.tablesError,
    this.loadedAt,
    this.viewAsRoleIds,
  });

  factory MetaSnapshot.loading(String profileId, MetadataSettings settings) => MetaSnapshot(
    profileId: profileId,
    status: MetaLoadStatus.loading,
    index: MetaIndex.empty,
    policy: AccessPolicy.unrestricted,
    tablesOutcome: MetaTablesOutcome.absent,
    settings: settings,
    identity: AccessIdentity.anonymous,
    isSqlite: false,
  );
  final String profileId;
  final MetaLoadStatus status;
  final MetaIndex index;
  final AccessPolicy policy;
  final MetaTablesOutcome tablesOutcome;
  final String? tablesError;
  final MetadataSettings settings;
  final AccessIdentity identity;
  final bool isSqlite;
  final DateTime? loadedAt;

  /// Role ids being previewed with "View as…", or null.
  final Set<String>? viewAsRoleIds;

  List<MetaProblem> get problems => [
    ...index.allProblems,
    ...policy.problems,
    if (tablesError != null) MetaProblem(MetaSourceKind.database, 'metadata tables', tablesError!),
  ];

  bool get hasAnyMetadata => !index.document.isEmpty;

  /// Is [schema].[table] one of dbscope's own metadata tables?
  bool isMetaTable(String schema, String table) => MetaTableNames.isMetaTable(
    schema,
    table,
    settings,
    sqlite: isSqlite,
  );

  /// The principal shown for "me" (`@me_principal`).
  String? get mePrincipal {
    final claimed = identity.claimedUser;
    if (claimed != null) return '${PrincipalPrefix.user}$claimed';
    return null;
  }
}

class _LoadArgs {
  const _LoadArgs(this.profile, this.executor);
  final ConnectionProfile profile;
  final DbExecutor executor;
}

class MetadataCache extends ChangeNotifier {
  MetadataCache._();
  static final instance = MetadataCache._();

  final Map<String, MetaSnapshot> _snapshots = {};
  final Map<String, _LoadArgs> _lastArgs = {};
  final Map<String, Future<void>> _inFlight = {};
  final Expando<String> _profileOfExecutor = Expando('metaProfile');

  /// Called after a reload so other windows refresh too. Wired by the
  /// connection registry to `bus.publish('meta.changed:<id>')`.
  Future<void> Function(String profileId)? onReloadedBroadcast;

  MetaSnapshot? snapshotFor(String? profileId) => profileId == null ? null : _snapshots[profileId];

  /// Snapshot for whichever profile [executor] belongs to.
  MetaSnapshot? snapshotForExecutor(DbExecutor executor) {
    final profileId = _profileOfExecutor[executor];
    return profileId == null ? null : _snapshots[profileId];
  }

  /// Access policy for [executor]'s profile, or unrestricted when no
  /// metadata is loaded (yet) for it.
  AccessPolicy policyForExecutor(DbExecutor executor) =>
      snapshotForExecutor(executor)?.policy ?? AccessPolicy.unrestricted;

  void attach(String profileId, DbExecutor executor) {
    _profileOfExecutor[executor] = profileId;
  }

  /// Loads (or reloads) metadata for [profile] over [executor]. Concurrent
  /// calls for the same profile share one load.
  Future<void> load(ConnectionProfile profile, DbExecutor executor) {
    attach(profile.id, executor);
    final existing = _inFlight[profile.id];
    final previousArgs = _lastArgs[profile.id];
    _lastArgs[profile.id] = _LoadArgs(profile, executor);
    if (existing != null) {
      final same =
          previousArgs != null &&
          identical(previousArgs.executor, executor) &&
          previousArgs.profile.toJson().toString() == profile.toJson().toString();
      if (same) return existing;
      // Different executor (a reconnect) or settings: the running load
      // answers an old question. Run a fresh one after it, so the newest
      // arguments always win.
      return existing.then((_) => load(profile, executor));
    }
    final previous = _snapshots[profile.id];
    if (previous == null) {
      _snapshots[profile.id] = MetaSnapshot.loading(
        profile.id,
        profile.metadata,
      );
      notifyListeners();
    }
    // A block body on purpose: `remove` returns this very future, and
    // whenComplete waits on any future its callback returns — returning it
    // would make the load wait on itself forever.
    final future = _load(profile, executor, previous?.viewAsRoleIds).whenComplete(() {
      unawaited(_inFlight.remove(profile.id));
    });
    _inFlight[profile.id] = future;
    return future;
  }

  /// Reloads with the last profile/executor, then tells other windows.
  Future<void> reload(String profileId, {bool broadcast = true}) async {
    final args = _lastArgs[profileId];
    if (args == null || !args.executor.isOpen) return;
    await load(args.profile, args.executor);
    if (broadcast) await onReloadedBroadcast?.call(profileId);
  }

  /// The profile changed (e.g. metadata settings edited): reload with it.
  Future<void> profileChanged(ConnectionProfile profile) async {
    final args = _lastArgs[profile.id];
    if (args == null || !args.executor.isOpen) return;
    await load(profile, args.executor);
  }

  void invalidate(String profileId) {
    _lastArgs.remove(profileId);
    if (_snapshots.remove(profileId) != null) notifyListeners();
  }

  /// "View as…" for managers. Pass null to stop previewing.
  void viewAs(String profileId, Set<String>? roleIds) {
    final snapshot = _snapshots[profileId];
    if (snapshot == null) return;
    _snapshots[profileId] = _withPolicy(snapshot, roleIds);
    notifyListeners();
  }

  MetaSnapshot _withPolicy(MetaSnapshot snapshot, Set<String>? viewAsRoleIds) {
    final policy = _resolvePolicy(
      index: snapshot.index,
      tablesOutcome: snapshot.tablesOutcome,
      tablesError: snapshot.tablesError,
      identity: snapshot.identity,
      ceilings: _ceilings[snapshot.profileId],
      settings: snapshot.settings,
      isSqlite: snapshot.isSqlite,
      viewAsRoleIds: viewAsRoleIds,
    );
    return MetaSnapshot(
      profileId: snapshot.profileId,
      status: snapshot.status,
      index: snapshot.index,
      policy: policy,
      tablesOutcome: snapshot.tablesOutcome,
      tablesError: snapshot.tablesError,
      settings: snapshot.settings,
      identity: snapshot.identity,
      isSqlite: snapshot.isSqlite,
      loadedAt: snapshot.loadedAt,
      viewAsRoleIds: viewAsRoleIds,
    );
  }

  final Map<String, PrivilegeCeilings?> _ceilings = {};

  Future<void> _load(
    ConnectionProfile profile,
    DbExecutor executor,
    Set<String>? viewAsRoleIds,
  ) async {
    final settings = profile.metadata;
    final sqlite = isSqliteExecutor(executor);

    // One after the other on purpose: they share the window's single
    // connection, and the loads are a handful of short catalog queries.
    final native = await NativeCommentSource.load(executor);
    var tables = await DbTableSource.load(executor, settings);
    // One retry: a connection blip during detection shouldn't lock a
    // connection read-only. A second failure still fails closed.
    if (tables.outcome == MetaTablesOutcome.unreadable) {
      tables = await DbTableSource.load(executor, settings);
    }
    final sidecar = settings.sidecarPath;
    final file = sidecar == null
        ? const MetaSourceData(source: MetaSourceKind.file)
        : await FileSource.load(sidecar);
    final overrides = ProfileOverrideSource.fromProfile(profile);

    // When the database carries access control, it is the only authority:
    // a local file (which the person running dbscope can edit) must not be
    // able to grant itself more than the shared rules allow.
    var fileData = file;
    final databaseHasAccessControl =
        tables.data.roles.isNotEmpty ||
        tables.data.grants.isNotEmpty ||
        tables.data.rows.any((metaRow) => metaRow.kind == MetaKinds.rbac);
    final fileHasAccessControl =
        file.roles.isNotEmpty ||
        file.grants.isNotEmpty ||
        file.members.isNotEmpty ||
        file.rows.any((metaRow) => metaRow.kind == MetaKinds.rbac);
    if (databaseHasAccessControl && fileHasAccessControl) {
      fileData = MetaSourceData(
        source: MetaSourceKind.file,
        rows: [
          for (final metaRow in file.rows)
            if (metaRow.kind != MetaKinds.rbac) metaRow,
        ],
        problems: [
          ...file.problems,
          const MetaProblem(
            MetaSourceKind.file,
            'access control',
            "The database defines access control, so the metadata file's "
                'roles, members, grants and rbac settings are ignored.',
          ),
        ],
        disabledRowIds: file.disabledRowIds,
      );
    }

    final document = mergeMetaSources([
      native,
      tables.data,
      fileData,
      overrides,
    ]);
    final index = MetaIndex.build(document);

    var identity = AccessIdentity(claimedUser: settings.claimedIdentity);
    PrivilegeCeilings? ceilings;
    final accessControlPossible =
        document.hasAccessControl || tables.outcome == MetaTablesOutcome.unreadable;
    if (accessControlPossible && !sqlite) {
      identity = AccessIdentity(
        postgresRoles: await _postgresRoles(executor),
        claimedUser: settings.claimedIdentity,
      );
      ceilings = await _privilegeCeilings(executor);
    }
    _ceilings[profile.id] = ceilings;

    final policy = _resolvePolicy(
      index: index,
      tablesOutcome: tables.outcome,
      tablesError: tables.error,
      identity: identity,
      ceilings: ceilings,
      settings: settings,
      isSqlite: sqlite,
      viewAsRoleIds: viewAsRoleIds,
    );

    _snapshots[profile.id] = MetaSnapshot(
      profileId: profile.id,
      status: MetaLoadStatus.ready,
      index: index,
      policy: policy,
      tablesOutcome: tables.outcome,
      tablesError: tables.error,
      settings: settings,
      identity: identity,
      isSqlite: sqlite,
      loadedAt: DateTime.now(),
      viewAsRoleIds: viewAsRoleIds,
    );
    notifyListeners();
  }

  static AccessPolicy _resolvePolicy({
    required MetaIndex index,
    required MetaTablesOutcome tablesOutcome,
    required String? tablesError,
    required AccessIdentity identity,
    required PrivilegeCeilings? ceilings,
    required MetadataSettings settings,
    required bool isSqlite,
    required Set<String>? viewAsRoleIds,
  }) {
    if (tablesOutcome == MetaTablesOutcome.unreadable) {
      return AccessPolicy.failClosed(
        tablesError ?? 'metadata tables unreadable',
      );
    }
    return AccessPolicy.resolve(
      document: index.document,
      settings: index.rbac,
      identity: identity,
      ceilings: ceilings,
      isMetaTable: (schema, table) => MetaTableNames.isMetaTable(
        schema,
        table,
        settings,
        sqlite: isSqlite,
      ),
      viewAsRoleIds: viewAsRoleIds,
      viewAsLabel: viewAsRoleIds == null ? null : (viewAsRoleIds.toList()..sort()).join(', '),
    );
  }

  /// The connected login plus every role it belongs to.
  static Future<Set<String>> _postgresRoles(DbExecutor executor) async {
    try {
      final result = await executor.execute(
        'SELECT r.rolname::text FROM pg_roles r '
        "WHERE pg_has_role(current_user, r.oid, 'member')",
      );
      return {for (final row in result.rows) row[0]! as String};
    } catch (_) {
      // No role info → no pg: principals. The policy degrades to claimed
      // identity and `everyone`, which only ever narrows access.
      return const {};
    }
  }

  /// Real privileges of the connected login, used as a ceiling. Table
  /// SELECT/UPDATE use the any-column variants so a login with column-level
  /// grants still sees the table; per-column caps fill in the detail.
  static Future<PrivilegeCeilings?> _privilegeCeilings(
    DbExecutor executor,
  ) async {
    try {
      final tableResult = await executor.execute('''
 SELECT n.nspname::text, c.relname::text,
 has_any_column_privilege(c.oid, 'SELECT'),
 has_table_privilege(c.oid, 'INSERT'),
 has_any_column_privilege(c.oid, 'UPDATE'),
 has_table_privilege(c.oid, 'DELETE')
 FROM pg_class c
 JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f')
 AND n.nspname NOT IN ('pg_catalog', 'information_schema')
 AND n.nspname NOT LIKE 'pg_toast%'
 ''');
      final tables = <String, ({bool select, bool insert, bool update, bool delete})>{};
      for (final row in tableResult.rows) {
        tables[PrivilegeCeilings.tableKey(
          row[0]! as String,
          row[1]! as String,
        )] = (
          select: row[2] == true,
          insert: row[3] == true,
          update: row[4] == true,
          delete: row[5] == true,
        );
      }
      final columnResult = await executor.execute('''
 SELECT n.nspname::text, c.relname::text, a.attname::text,
 has_column_privilege(c.oid, a.attnum, 'SELECT'),
 has_column_privilege(c.oid, a.attnum, 'UPDATE')
 FROM pg_attribute a
 JOIN pg_class c ON c.oid = a.attrelid
 JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE a.attnum > 0 AND NOT a.attisdropped
 AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
 AND n.nspname NOT IN ('pg_catalog', 'information_schema')
 AND (
 (NOT has_table_privilege(c.oid, 'SELECT')
 AND has_any_column_privilege(c.oid, 'SELECT'))
 OR (NOT has_table_privilege(c.oid, 'UPDATE')
 AND has_any_column_privilege(c.oid, 'UPDATE'))
 )
 ''');
      final columns = <String, ({bool select, bool update})>{};
      for (final row in columnResult.rows) {
        columns[PrivilegeCeilings.columnKey(
          row[0]! as String,
          row[1]! as String,
          row[2]! as String,
        )] = (
          select: row[3] == true,
          update: row[4] == true,
        );
      }
      return PrivilegeCeilings(tables: tables, columns: columns);
    } catch (_) {
      // Ceilings are an extra guard on top of the grants; if the catalog
      // query fails the grants still apply, and Postgres still refuses
      // anything the login can't do.
      return null;
    }
  }
}
