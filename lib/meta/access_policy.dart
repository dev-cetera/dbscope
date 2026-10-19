// AccessPolicy — who sees what, for one connection and one identity.
//
// Resolution (plan.md "Resolution"):
//   1. principals: pg:<current user and every role they belong to>,
//      user:<claimed identity>, filtered by the rbac identity mode;
//   2. roles: every role with a matching member (or whose db_role the user
//      belongs to), plus `everyone`, expanded through `inherits`;
//   3. collect every matching grant from all held roles;
//   4. the most specific grant wins (depth first, then segment score);
//   5. among equally specific grants, the most generous level wins;
//   6. nothing matched → the rbac default;
//   7. ceilings: a `none` table makes its columns `none`; real Postgres
//      privileges cap everything. (The read-only connection cap is applied
//      by the caller, because it can change while connected.)
//
// Pure: no I/O. The cache gathers principals and privileges, then calls
// [AccessPolicy.resolve].

import 'meta_models.dart';
import 'selector.dart';

/// Why a level was decided — shown in "Why can't I see this?".
class AccessDecision {
  const AccessDecision({
    required this.level,
    required this.defaultHidden,
    required this.reason,
    this.grant,
  });
  final AccessLevel level;
  final bool defaultHidden;

  /// The grant that decided it, or null when the default or a ceiling did.
  final MetaGrant? grant;
  final String reason;

  static const unrestricted = AccessDecision(
    level: AccessLevel.full,
    defaultHidden: false,
    reason: 'No access control on this connection.',
  );

  AccessDecision capped(AccessLevel ceiling, String why) {
    if (level.index <= ceiling.index) return this;
    return AccessDecision(
      level: ceiling,
      defaultHidden: defaultHidden,
      grant: grant,
      reason: '$reason Capped at ${ceiling.name}: $why',
    );
  }

  bool get canSeeValues => level.atLeast(AccessLevel.read);
  bool get canEdit => level.atLeast(AccessLevel.edit);
  bool get isNone => level == AccessLevel.none;
  bool get isMasked => level == AccessLevel.masked;
}

/// Real Postgres privileges of the connected login, used as a ceiling.
class PrivilegeCeilings {
  const PrivilegeCeilings({this.tables = const {}, this.columns = const {}});
  final Map<String, ({bool select, bool insert, bool update, bool delete})> tables;

  /// Only filled for tables where the login has column-level but not
  /// table-level SELECT.
  final Map<String, ({bool select, bool update})> columns;

  static String tableKey(String schema, String table) => '$schema\u0000$table';
  static String columnKey(String schema, String table, String column) =>
      '$schema\u0000$table\u0000$column';

  AccessLevel? tableCeiling(String schema, String table) {
    final privileges = tables[tableKey(schema, table)];
    if (privileges == null) return null;
    if (!privileges.select) return AccessLevel.none;
    if (privileges.update && privileges.insert && privileges.delete) {
      return AccessLevel.full;
    }
    if (privileges.update) return AccessLevel.edit;
    return AccessLevel.read;
  }

  AccessLevel? columnCeiling(String schema, String table, String column) {
    final privileges = columns[columnKey(schema, table, column)];
    if (privileges == null) return null;
    if (!privileges.select) return AccessLevel.none;
    if (privileges.update) return AccessLevel.edit;
    return AccessLevel.read;
  }
}

/// Identity inputs gathered at connect time.
class AccessIdentity {
  const AccessIdentity({this.postgresRoles = const {}, this.claimedUser});

  /// The connected Postgres user and every role it is a member of (no
  /// `pg:` prefix). Empty for backends without logins (SQLite).
  final Set<String> postgresRoles;

  /// The email typed into dbscope preferences, if any.
  final String? claimedUser;

  static const anonymous = AccessIdentity();
}

class AccessPolicy {
  const AccessPolicy._({
    required this.active,
    required this.failedClosed,
    this.failureReason,
    required this.roleIds,
    required this.capabilities,
    required this.defaultLevel,
    required this.identityMode,
    required this.principals,
    this.viewingAs,
    required List<MetaGrant> grants,
    PrivilegeCeilings? ceilings,
    bool Function(String schema, String table)? isMetaTable,
    this.problems = const [],
  }) : _grants = grants,
       _ceilings = ceilings,
       _isMetaTable = isMetaTable;

  /// The rules exist but can't be read. Read-only, no capabilities.
  factory AccessPolicy.failClosed(String reason) => AccessPolicy._(
    active: true,
    failedClosed: true,
    failureReason: reason,
    roleIds: const {},
    capabilities: const {},
    defaultLevel: AccessLevel.read,
    identityMode: IdentityMode.either,
    principals: const {},
    grants: const [],
  );

  /// Resolves the policy for one identity. When [viewAsRoleIds] is set (a
  /// manager's "View as…"), those roles replace the identity's own.
  factory AccessPolicy.resolve({
    required MetaDocument document,
    required RbacSettings settings,
    required AccessIdentity identity,
    PrivilegeCeilings? ceilings,
    bool Function(String schema, String table)? isMetaTable,
    Set<String>? viewAsRoleIds,
    String? viewAsLabel,
  }) {
    if (!document.hasAccessControl) return AccessPolicy.unrestricted;
    final problems = <MetaProblem>[];

    // 1. Principals.
    final principals = <String>{};
    final allowVerified = settings.identity != IdentityMode.claimed;
    final allowClaimed = settings.identity != IdentityMode.verified;
    if (allowVerified) {
      for (final role in identity.postgresRoles) {
        principals.add('${PrincipalPrefix.pg}$role');
      }
    }
    final claimed = identity.claimedUser?.trim();
    if (allowClaimed && claimed != null && claimed.isNotEmpty) {
      principals.add('${PrincipalPrefix.user}${claimed.toLowerCase()}');
    }

    // 2. Roles.
    final rolesById = {for (final role in document.roles) role.id: role};
    final Set<String> direct;
    if (viewAsRoleIds != null) {
      direct = {...viewAsRoleIds};
    } else {
      direct = <String>{};
      for (final member in document.members) {
        if (_principalMatches(member.principal, principals)) {
          direct.add(member.roleId);
        }
      }
      if (allowVerified) {
        for (final role in document.roles) {
          final dbRole = role.dbRole;
          if (dbRole != null && identity.postgresRoles.contains(dbRole)) {
            direct.add(role.id);
          }
        }
      }
    }
    direct.add(kEveryoneRoleId);
    final held = _expandInherits(direct, rolesById, problems);

    final capabilities = <Capability>{
      for (final id in held) ...?rolesById[id]?.capabilities,
    };

    final grants = [
      for (final grant in document.grants)
        if (grant.enabled && held.contains(grant.roleId)) grant,
    ];

    return AccessPolicy._(
      active: true,
      failedClosed: false,
      roleIds: held,
      capabilities: capabilities,
      defaultLevel: settings.defaultLevel,
      identityMode: settings.identity,
      principals: principals,
      viewingAs: viewAsLabel,
      grants: grants,
      ceilings: ceilings,
      isMetaTable: isMetaTable,
      problems: problems,
    );
  }

  /// False when the connection has no roles, grants or rbac settings: every
  /// decision is `full` and every capability is allowed.
  final bool active;

  /// True when the rules exist but could not be read: everything is capped
  /// at `read` and every capability is off.
  final bool failedClosed;
  final String? failureReason;

  final Set<String> roleIds;
  final Set<Capability> capabilities;
  final AccessLevel defaultLevel;
  final IdentityMode identityMode;
  final Set<String> principals;

  /// Non-null when a manager is previewing the UI as someone else.
  final String? viewingAs;

  final List<MetaGrant> _grants;
  final PrivilegeCeilings? _ceilings;

  /// Hides dbscope's own tables from non-managers.
  final bool Function(String schema, String table)? _isMetaTable;

  final List<MetaProblem> problems;

  static const unrestricted = AccessPolicy._(
    active: false,
    failedClosed: false,
    roleIds: {},
    capabilities: {...Capability.values},
    defaultLevel: AccessLevel.full,
    identityMode: IdentityMode.either,
    principals: {},
    grants: [],
  );

  static bool _principalMatches(String principal, Set<String> principals) {
    if (principal == '*') return true;
    if (principal.startsWith(PrincipalPrefix.user)) {
      return principals.contains(principal.toLowerCase());
    }
    return principals.contains(principal);
  }

  static Set<String> _expandInherits(
    Set<String> direct,
    Map<String, MetaRole> rolesById,
    List<MetaProblem> problems,
  ) {
    final held = <String>{};
    void visit(String id, List<String> path) {
      if (path.contains(id)) {
        problems.add(
          MetaProblem(
            rolesById[id]?.source ?? MetaSourceKind.database,
            id,
            'Role inheritance cycle: ${[...path, id].join(' → ')}. Broken.',
          ),
        );
        return;
      }
      if (!held.add(id)) return;
      for (final parent in rolesById[id]?.inherits ?? const <String>[]) {
        visit(parent, [...path, id]);
      }
    }

    for (final id in direct) {
      visit(id, const []);
    }
    return held;
  }

  bool can(Capability capability) {
    if (!active) return true;
    return capabilities.contains(capability);
  }

  /// Short label for banners: "View as support", "Roles: owner, everyone".
  String get summary {
    if (!active) return 'No access control';
    if (failedClosed) {
      return 'Read-only: ${failureReason ?? 'rules unreadable'}';
    }
    final roles = (roleIds.toList()..sort()).join(', ');
    if (viewingAs != null) return 'Viewing as $viewingAs ($roles)';
    return 'Roles: $roles';
  }

  // ─── Decisions ─────────────────────────────────────────────────────

  AccessDecision forTable(String schema, String table) {
    if (!active) return AccessDecision.unrestricted;
    if (failedClosed) return _failedClosedDecision;
    if (_isMetaTable?.call(schema, table) ?? false) {
      if (!capabilities.contains(Capability.manage)) {
        return const AccessDecision(
          level: AccessLevel.none,
          defaultHidden: false,
          reason: "dbscope's own tables are only shown to roles with manage.",
        );
      }
    }
    var decision = _decide(
      (selector) => selector.matchesTable(schema, table),
      '$schema.$table',
    );
    // No table-level grant applied (the default decided): a column-level
    // grant that names this table literally still opens it, to the level of
    // its most generous column grant — otherwise `default: none` + a grant
    // on one column could never show that column. Other columns keep
    // falling to the default.
    if (decision.grant == null) {
      MetaGrant? opener;
      for (final grant in _grants) {
        if (!grant.target.isColumnLevel) continue;
        if (!grant.target.namesColumnOfTable(schema, table)) continue;
        if (opener == null || grant.level.index > opener.level.index) {
          opener = grant;
        }
      }
      if (opener != null && opener.level.index > decision.level.index) {
        decision = AccessDecision(
          level: opener.level,
          defaultHidden: false,
          grant: opener,
          reason:
              'Opened by column grant ${opener.id} (role ${opener.roleId} → '
              '${opener.target.raw}).',
        );
      }
    }
    final ceiling = _ceilings?.tableCeiling(schema, table);
    if (ceiling != null) {
      decision = decision.capped(ceiling, 'Postgres privileges of this login.');
    }
    return decision;
  }

  /// [isPrimaryKey] columns are never `none`: pagination and edits need
  /// them, so the floor for a PK is `masked`.
  AccessDecision forColumn(
    String schema,
    String table,
    String column, {
    bool isPrimaryKey = false,
  }) {
    if (!active) return AccessDecision.unrestricted;
    final tableDecision = forTable(schema, table);
    if (tableDecision.isNone) return tableDecision;
    if (failedClosed) return _failedClosedDecision;
    var decision = _decide(
      (selector) => selector.matchesColumn(schema, table, column),
      '$schema.$table.$column',
    );
    final ceiling = _ceilings?.columnCeiling(schema, table, column);
    if (ceiling != null) {
      decision = decision.capped(ceiling, 'Postgres column privileges.');
    }
    final tableCeiling = _ceilings?.tableCeiling(schema, table);
    if (tableCeiling != null && ceiling == null) {
      decision = decision.capped(tableCeiling, 'Postgres table privileges.');
    }
    // The masked floor for keys applies to metadata decisions only: when
    // Postgres itself denies the column, fetching it would just fail.
    if (isPrimaryKey && decision.isNone && ceiling != AccessLevel.none) {
      return AccessDecision(
        level: AccessLevel.masked,
        defaultHidden: decision.defaultHidden,
        grant: decision.grant,
        reason:
            '${decision.reason} Primary keys are always fetched (paging and '
            'edits need them), so the floor is masked.',
      );
    }
    return decision;
  }

  AccessDecision forQuery(String queryId) {
    if (!active) return AccessDecision.unrestricted;
    if (failedClosed) return _failedClosedDecision;
    return _decide(
      (selector) => selector.matchesQuery(queryId),
      'query:$queryId',
    );
  }

  AccessDecision forQueryColumn(String queryId, String column) {
    if (!active) return AccessDecision.unrestricted;
    final queryDecision = forQuery(queryId);
    if (queryDecision.isNone) return queryDecision;
    if (failedClosed) return _failedClosedDecision;
    return _decide(
      (selector) => selector.matchesQueryColumn(queryId, column),
      'query:$queryId.$column',
    );
  }

  AccessDecision get _failedClosedDecision => AccessDecision(
    level: AccessLevel.read,
    defaultHidden: false,
    reason:
        'Access rules exist but could not be read (${failureReason ?? '?'}), '
        'so this connection is read-only.',
  );

  /// Steps 3–6: most specific wins; ties → most generous; none → default.
  AccessDecision _decide(bool Function(Selector) applies, String what) {
    MetaGrant? best;
    var bestSpecificity = -1;
    final tied = <MetaGrant>[];
    for (final grant in _grants) {
      if (!applies(grant.target)) continue;
      final specificity = grant.target.specificity;
      if (specificity > bestSpecificity) {
        bestSpecificity = specificity;
        best = grant;
        tied
          ..clear()
          ..add(grant);
      } else if (specificity == bestSpecificity) {
        tied.add(grant);
        if (grant.level.index > best!.level.index) best = grant;
      }
    }
    if (best == null) {
      return AccessDecision(
        level: defaultLevel,
        defaultHidden: false,
        reason: 'No grant matches $what; the default is ${defaultLevel.name}.',
      );
    }
    final winningLevel = best.level;
    final atWinningLevel = tied.where((grant) => grant.level == winningLevel);
    final hidden = atWinningLevel.every((grant) => grant.defaultHidden);
    final note = best.note == null ? '' : ' — ${best.note}';
    return AccessDecision(
      level: winningLevel,
      defaultHidden: hidden,
      grant: best,
      reason:
          'Grant ${best.id}: role ${best.roleId} → ${best.target.raw} is '
          '${best.level.name}$note',
    );
  }
}
