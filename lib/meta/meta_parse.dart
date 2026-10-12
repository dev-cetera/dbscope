// Turns raw maps (from a YAML/JSON file, or from the dbscope tables) into
// typed metadata. Tolerant by design: every unusable entry becomes a
// MetaProblem and parsing continues.
//
// File format (YAML or JSON — JSON is valid YAML):
//
//   format: 1                       # optional
//   include: [base.dbscope.yaml]    # resolved by the file source, not here
//   rbac: { default: read, identity: claimed }   # shorthand for an rbac row
//   meta:
//     - id: items.label
//       target: public.items
//       kind: display
//       spec: { rowLabel: "{name}" }   # or put the spec fields inline
//   roles:
//     - { id: owner, label: Owner, capabilities: [query, manage] }
//   members:
//     - { role: owner, principal: "user:me@example.com" }
//   grants:
//     - { id: g1, role: everyone, target: "*.*.password_hash", level: none }

import 'dart:convert';

import 'meta_models.dart';
import 'selector.dart';

/// Keys a meta entry may carry besides its spec. Anything else on an entry
/// without an explicit `spec:` is treated as the spec (inline form).
const _metaEntryKeys = <String>{
  'id',
  'target',
  'kind',
  'spec',
  'priority',
  'enabled',
};

/// Normalises YAML/JSON-decoded values (YamlMap, YamlList, `Map<dynamic, …>`)
/// into plain `Map<String, Object?>` / `List<Object?>`.
Object? plainJson(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries) e.key.toString(): plainJson(e.value),
    };
  }
  if (value is List) return [for (final e in value) plainJson(e)];
  return value;
}

/// A database `spec` cell may arrive decoded (jsonb → Map) or as text.
Map<String, Object?> decodeSpecCell(Object? cell) {
  if (cell is Map) return plainJson(cell)! as Map<String, Object?>;
  if (cell is String && cell.trim().isNotEmpty) {
    final decoded = jsonDecode(cell);
    if (decoded is Map) return plainJson(decoded)! as Map<String, Object?>;
  }
  return const {};
}

List<String> decodeStringListCell(Object? cell) {
  var value = cell;
  if (value is String && value.trim().startsWith('[')) {
    value = jsonDecode(value);
  }
  if (value is List) {
    return [
      for (final e in value)
        if (e != null) e.toString(),
    ];
  }
  if (value is String && value.isNotEmpty) return [value];
  return const [];
}

bool _bool(Object? v, {required bool fallback}) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1' || v == 't';
  return fallback;
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String? _str(Object? v) {
  if (v is String && v.trim().isNotEmpty) return v.trim();
  return null;
}

/// Accumulates parsed entries for one source.
class MetaSourceBuilder {
  MetaSourceBuilder(this.source);
  final MetaSourceKind source;
  final List<MetaRow> rows = [];
  final List<MetaRole> roles = [];
  final List<MetaRoleMember> members = [];
  final List<MetaGrant> grants = [];
  final List<MetaProblem> problems = [];
  final Set<String> disabledRowIds = {};
  final Set<String> disabledGrantIds = {};

  MetaSourceData build() => MetaSourceData(
    source: source,
    rows: rows,
    roles: roles,
    members: members,
    grants: grants,
    problems: problems,
    disabledRowIds: disabledRowIds,
    disabledGrantIds: disabledGrantIds,
  );

  /// One metadata row. [where] labels problems (file path, table name).
  void addMetaEntry(Map<String, Object?> entry, {required String where}) {
    final id = _str(entry['id']);
    final kind = _str(entry['kind']);
    final targetRaw = _str(entry['target']) ?? '*';
    if (id == null) {
      problems.add(MetaProblem(source, where, 'A meta row needs an id.'));
      return;
    }
    // Entries apply in order, so a later `enabled: false` (an including
    // file, say) removes an id defined earlier in this same source, and
    // every lower source.
    if (!_bool(entry['enabled'], fallback: true)) {
      rows.removeWhere((r) => r.id == id);
      disabledRowIds.add(id);
      return;
    }
    if (kind == null) {
      problems.add(MetaProblem(source, id, 'A meta row needs a kind.'));
      return;
    }
    final target = Selector.tryParse(targetRaw);
    if (target == null) {
      problems.add(MetaProblem(source, id, 'Bad target "$targetRaw".'));
      return;
    }
    if (!MetaKinds.known.contains(kind)) {
      problems.add(
        MetaProblem(source, id, 'Unknown kind "$kind" — kept for plugins.'),
      );
    }
    final Map<String, Object?> spec;
    if (entry.containsKey('spec')) {
      try {
        spec = decodeSpecCell(entry['spec']);
      } catch (e) {
        problems.add(MetaProblem(source, id, 'spec is not valid JSON: $e'));
        return;
      }
    } else {
      spec = {
        for (final e in entry.entries)
          if (!_metaEntryKeys.contains(e.key)) e.key: e.value,
      };
    }
    disabledRowIds.remove(id);
    rows.removeWhere((r) => r.id == id);
    rows.add(
      MetaRow(
        id: id,
        target: target,
        kind: kind,
        spec: spec,
        priority: _int(entry['priority']),
        source: source,
      ),
    );
  }

  void addRole(Map<String, Object?> entry, {required String where}) {
    final id = _str(entry['id']);
    if (id == null) {
      problems.add(MetaProblem(source, where, 'A role needs an id.'));
      return;
    }
    final List<String> capabilityNames;
    final List<String> inherits;
    final Map<String, Object?> spec;
    try {
      capabilityNames = decodeStringListCell(entry['capabilities']);
      inherits = decodeStringListCell(entry['inherits']);
      spec = entry['spec'] == null ? const {} : decodeSpecCell(entry['spec']);
    } on FormatException catch (e) {
      problems.add(MetaProblem(source, id, 'Not valid JSON: ${e.message}'));
      return;
    }
    final capabilities = <Capability>{};
    for (final raw in capabilityNames) {
      final c = Capability.tryParse(raw);
      if (c == null) {
        problems.add(MetaProblem(source, id, 'Unknown capability "$raw".'));
      } else {
        capabilities.add(c);
      }
    }
    roles.removeWhere((r) => r.id == id);
    roles.add(
      MetaRole(
        id: id,
        label: _str(entry['label']) ?? id,
        description: _str(entry['description']),
        inherits: inherits,
        capabilities: capabilities,
        dbRole: _str(entry['db_role']) ?? _str(entry['dbRole']),
        spec: spec,
        source: source,
      ),
    );
  }

  void addMember(Map<String, Object?> entry, {required String where}) {
    final roleId = _str(entry['role_id']) ?? _str(entry['role']);
    final principal = _str(entry['principal']);
    if (roleId == null || principal == null) {
      problems.add(
        MetaProblem(source, where, 'A role member needs role and principal.'),
      );
      return;
    }
    final known =
        principal == '*' ||
        principal.startsWith(PrincipalPrefix.pg) ||
        principal.startsWith(PrincipalPrefix.user);
    if (!known) {
      problems.add(
        MetaProblem(
          source,
          '$roleId ← $principal',
          'Principal must be pg:<role>, user:<email> or *.',
        ),
      );
      return;
    }
    members.add(
      MetaRoleMember(roleId: roleId, principal: principal, source: source),
    );
  }

  void addGrant(Map<String, Object?> entry, {required String where}) {
    final id = _str(entry['id']);
    final roleId = _str(entry['role_id']) ?? _str(entry['role']);
    final targetRaw = _str(entry['target']);
    if (id == null) {
      problems.add(MetaProblem(source, where, 'A grant needs an id.'));
      return;
    }
    if (!_bool(entry['enabled'], fallback: true)) {
      grants.removeWhere((g) => g.id == id);
      disabledGrantIds.add(id);
      return;
    }
    if (roleId == null || targetRaw == null) {
      problems.add(MetaProblem(source, id, 'A grant needs role and target.'));
      return;
    }
    final level = AccessLevel.tryParse(entry['level']);
    if (level == null) {
      problems.add(
        MetaProblem(
          source,
          id,
          'Grant level must be none, masked, read, edit or full.',
        ),
      );
      return;
    }
    final target = Selector.tryParse(targetRaw);
    if (target == null) {
      problems.add(MetaProblem(source, id, 'Bad target "$targetRaw".'));
      return;
    }
    final Map<String, Object?> spec;
    try {
      spec = entry['spec'] == null ? const {} : decodeSpecCell(entry['spec']);
    } on FormatException catch (e) {
      problems.add(
        MetaProblem(source, id, 'spec is not valid JSON: ${e.message}'),
      );
      return;
    }
    disabledGrantIds.remove(id);
    grants.removeWhere((g) => g.id == id);
    grants.add(
      MetaGrant(
        id: id,
        roleId: roleId,
        target: target,
        level: level,
        defaultHidden: _bool(
          entry['default_hidden'] ?? entry['defaultHidden'],
          fallback: false,
        ),
        note: _str(entry['note']),
        spec: spec,
        source: source,
      ),
    );
  }

  /// A whole document map (file form). Includes are ignored here — the
  /// file source resolves them before calling this.
  void addDocument(Map<String, Object?> document, {required String where}) {
    final format = document['format'];
    if (format != null) {
      addMetaEntry({
        'id': 'format',
        'target': '*',
        'kind': MetaKinds.format,
        'spec': {'version': format},
      }, where: where);
    }
    final rbac = document['rbac'];
    if (rbac is Map) {
      addMetaEntry({
        'id': 'rbac',
        'target': '*',
        'kind': MetaKinds.rbac,
        'spec': plainJson(rbac),
      }, where: where);
    }
    void each(
      String key,
      void Function(Map<String, Object?>, {required String where}) add,
    ) {
      final list = document[key];
      if (list == null) return;
      if (list is! List) {
        problems.add(MetaProblem(source, where, '"$key" must be a list.'));
        return;
      }
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is Map) {
          add(
            plainJson(item)! as Map<String, Object?>,
            where: '$where $key[$i]',
          );
        } else {
          problems.add(
            MetaProblem(source, '$where $key[$i]', 'Entry must be a map.'),
          );
        }
      }
    }

    each('meta', addMetaEntry);
    each('roles', addRole);
    each('members', addMember);
    each('role_members', addMember);
    each('grants', addGrant);
  }
}
