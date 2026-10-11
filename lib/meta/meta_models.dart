// Plain data types for schema metadata and access control.
//
// Everything here is pure Dart (no Flutter, no I/O) so the resolver and the
// access policy can be unit-tested without a database. Parsing is tolerant:
// a malformed row becomes a [MetaProblem], never an exception, because a
// broken metadata row must never stop a connection.

import 'selector.dart';

/// Where a row came from, in precedence order (later wins on equal
/// specificity, and replaces a lower source's row with the same id).
enum MetaSourceKind {
  /// Postgres `COMMENT ON` descriptions.
  native,

  /// The `dbscope` schema / `_dbscope_*` tables in the database itself.
  database,

  /// The profile's sidecar file (YAML or JSON).
  file,

  /// This machine's per-profile overrides (soft-delete column, tenant).
  profile
  ;

  String get label => switch (this) {
    MetaSourceKind.native => 'database comments',
    MetaSourceKind.database => 'metadata tables',
    MetaSourceKind.file => 'metadata file',
    MetaSourceKind.profile => 'profile overrides',
  };
}

/// Every metadata kind dbscope understands. Unknown kinds are kept on the
/// row (so a plugin can read them) but otherwise ignored.
abstract final class MetaKinds {
  static const format = 'format';
  static const rbac = 'rbac';
  static const describe = 'describe';
  static const display = 'display';
  static const sensitive = 'sensitive';
  static const policy = 'policy';
  static const ai = 'ai';
  static const link = 'link';
  static const action = 'action';
  static const query = 'query';
  static const chart = 'chart';
  static const check = 'check';
  static const dashboard = 'dashboard';

  /// Kinds whose rows merge field by field into one effective value per
  /// target. Every other known kind is a list of independent entries.
  static const scalar = {
    format,
    rbac,
    describe,
    display,
    sensitive,
    policy,
    ai,
  };

  static const known = {
    format,
    rbac,
    describe,
    display,
    sensitive,
    policy,
    ai,
    link,
    action,
    query,
    chart,
    check,
    dashboard,
  };
}

/// The format version this build understands. A document declaring a
/// higher version still loads (unknown fields are ignored) but reports a
/// problem so the user knows something may be missing.
const int kSupportedMetaFormatVersion = 1;

/// One metadata row, from any source.
class MetaRow {
  final String id;
  final Selector target;
  final String kind;
  final Map<String, Object?> spec;
  final int priority;
  final bool enabled;
  final MetaSourceKind source;

  const MetaRow({
    required this.id,
    required this.target,
    required this.kind,
    required this.spec,
    this.priority = 0,
    this.enabled = true,
    required this.source,
  });

  bool get isScalarKind => MetaKinds.scalar.contains(kind);
}

/// A row or file that could not be used, with the reason. Shown in the
/// Metadata problems panel; never fatal.
class MetaProblem {
  final MetaSourceKind source;
  final String where;
  final String message;
  const MetaProblem(this.source, this.where, this.message);

  @override
  String toString() => '[${source.label}] $where: $message';
}

/// Ordered access levels. Each level includes everything below it.
enum AccessLevel {
  none,
  masked,
  read,
  edit,
  full
  ;

  bool atLeast(AccessLevel other) => index >= other.index;

  static AccessLevel? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final level in AccessLevel.values) {
      if (level.name == raw.trim().toLowerCase()) return level;
    }
    return null;
  }

  static AccessLevel min(AccessLevel a, AccessLevel b) =>
      a.index <= b.index ? a : b;

  static AccessLevel max(AccessLevel a, AccessLevel b) =>
      a.index >= b.index ? a : b;
}

/// Tool features a role may use. Capabilities add up across roles.
enum Capability {
  /// Free SQL in the Query tab (and the AI SQL assistant that writes it).
  query,

  /// Export rows to a file, and copy tables between databases.
  export,

  /// Send schema or values to an AI provider.
  ai,

  /// Run write (`exec`) actions.
  exec,

  /// Edit metadata and access control; use "View as…".
  manage
  ;

  static Capability? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final c in Capability.values) {
      if (c.name == raw.trim().toLowerCase()) return c;
    }
    return null;
  }
}

/// How identity is established. See plan.md "Identity".
enum IdentityMode {
  /// Only `pg:` principals (tied to the database login).
  verified,

  /// Only `user:` principals (typed into dbscope preferences).
  claimed,

  /// Both.
  either
  ;

  static IdentityMode? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final m in IdentityMode.values) {
      if (m.name == raw.trim().toLowerCase()) return m;
    }
    return null;
  }
}

class MetaRole {
  final String id;
  final String label;
  final String? description;
  final List<String> inherits;
  final Set<Capability> capabilities;
  final String? dbRole;
  final Map<String, Object?> spec;
  final MetaSourceKind source;

  const MetaRole({
    required this.id,
    required this.label,
    this.description,
    this.inherits = const [],
    this.capabilities = const {},
    this.dbRole,
    this.spec = const {},
    required this.source,
  });
}

/// Principal prefixes for [MetaRoleMember.principal].
abstract final class PrincipalPrefix {
  static const pg = 'pg:';
  static const user = 'user:';
}

class MetaRoleMember {
  final String roleId;

  /// `pg:<role>` (verified), `user:<email>` (claimed) or `*` (everyone).
  final String principal;
  final MetaSourceKind source;

  const MetaRoleMember({
    required this.roleId,
    required this.principal,
    required this.source,
  });
}

class MetaGrant {
  final String id;
  final String roleId;
  final Selector target;
  final AccessLevel level;
  final bool defaultHidden;
  final String? note;
  final bool enabled;
  final Map<String, Object?> spec;
  final MetaSourceKind source;

  const MetaGrant({
    required this.id,
    required this.roleId,
    required this.target,
    required this.level,
    this.defaultHidden = false,
    this.note,
    this.enabled = true,
    this.spec = const {},
    required this.source,
  });
}

/// The built-in role every user holds.
const String kEveryoneRoleId = 'everyone';

/// Everything loaded for one connection, after sources are merged.
class MetaDocument {
  /// Rows keyed by id (higher source already replaced lower ones; disabled
  /// rows removed).
  final List<MetaRow> rows;
  final List<MetaRole> roles;
  final List<MetaRoleMember> members;
  final List<MetaGrant> grants;
  final List<MetaProblem> problems;

  /// True when any source contributed roles or grants — i.e. access
  /// control is in play for this connection.
  final bool hasAccessControl;

  const MetaDocument({
    this.rows = const [],
    this.roles = const [],
    this.members = const [],
    this.grants = const [],
    this.problems = const [],
    this.hasAccessControl = false,
  });

  static const empty = MetaDocument();

  bool get isEmpty =>
      rows.isEmpty && roles.isEmpty && members.isEmpty && grants.isEmpty;

  Iterable<MetaRow> rowsOfKind(String kind) =>
      rows.where((r) => r.kind == kind);
}

/// One source's raw contribution before merging.
class MetaSourceData {
  final MetaSourceKind source;
  final List<MetaRow> rows;
  final List<MetaRole> roles;
  final List<MetaRoleMember> members;
  final List<MetaGrant> grants;
  final List<MetaProblem> problems;

  /// Row ids explicitly switched off by this source (`enabled: false`).
  /// They remove the same id from every lower source.
  final Set<String> disabledRowIds;
  final Set<String> disabledGrantIds;

  const MetaSourceData({
    required this.source,
    this.rows = const [],
    this.roles = const [],
    this.members = const [],
    this.grants = const [],
    this.problems = const [],
    this.disabledRowIds = const {},
    this.disabledGrantIds = const {},
  });
}

/// Merges sources lowest-precedence first. Same id → the later source
/// wins; `enabled: false` in a later source removes the id.
MetaDocument mergeMetaSources(List<MetaSourceData> sources) {
  final ordered = [...sources]
    ..sort((a, b) => a.source.index.compareTo(b.source.index));
  final rowsById = <String, MetaRow>{};
  final rolesById = <String, MetaRole>{};
  final grantsById = <String, MetaGrant>{};
  final members = <String, MetaRoleMember>{};
  final problems = <MetaProblem>[];
  var hasAccessControl = false;

  for (final source in ordered) {
    problems.addAll(source.problems);
    for (final id in source.disabledRowIds) {
      rowsById.remove(id);
    }
    for (final row in source.rows) {
      rowsById[row.id] = row;
    }
    for (final role in source.roles) {
      rolesById[role.id] = role;
      hasAccessControl = true;
    }
    for (final member in source.members) {
      members['${member.roleId}\u0000${member.principal}'] = member;
    }
    for (final id in source.disabledGrantIds) {
      grantsById.remove(id);
    }
    for (final grant in source.grants) {
      grantsById[grant.id] = grant;
      hasAccessControl = true;
    }
  }

  // An `rbac` settings row alone also switches access control on.
  if (rowsById.values.any((r) => r.kind == MetaKinds.rbac)) {
    hasAccessControl = true;
  }

  final formatRow = rowsById.values
      .where((r) => r.kind == MetaKinds.format)
      .firstOrNull;
  final version = formatRow?.spec['version'];
  if (version is num && version > kSupportedMetaFormatVersion) {
    problems.add(
      MetaProblem(
        formatRow!.source,
        formatRow.id,
        'Format version $version is newer than this dbscope understands '
        '($kSupportedMetaFormatVersion). Unknown fields are ignored.',
      ),
    );
  }

  return MetaDocument(
    rows: rowsById.values.toList(),
    roles: rolesById.values.toList(),
    members: members.values.toList(),
    grants: grantsById.values.toList(),
    problems: problems,
    hasAccessControl: hasAccessControl,
  );
}

// ─── Typed specs ────────────────────────────────────────────────────────
//
// Each spec reads a (possibly merged) JSON map. Missing or wrong-typed
// fields fall back to null/empty: the problems panel catches typos via
// [validateMetaRow], the specs themselves never throw.

String? specString(Map<String, Object?> spec, String key) {
  final v = spec[key];
  if (v is String && v.trim().isNotEmpty) return v;
  return null;
}

bool specBool(Map<String, Object?> spec, String key) {
  final v = spec[key];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return false;
}

int? specInt(Map<String, Object?> spec, String key) {
  final v = spec[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

num? specNum(Map<String, Object?> spec, String key) {
  final v = spec[key];
  if (v is num) return v;
  if (v is String) return num.tryParse(v);
  return null;
}

List<String> specStringList(Map<String, Object?> spec, String key) {
  final v = spec[key];
  if (v is List) {
    return [
      for (final e in v)
        if (e is String) e,
    ];
  }
  if (v is String && v.isNotEmpty) return [v];
  return const [];
}

Map<String, Object?> specMap(Map<String, Object?> spec, String key) {
  final v = spec[key];
  if (v is Map) return {for (final e in v.entries) e.key.toString(): e.value};
  return const {};
}

List<Map<String, Object?>> specMapList(Map<String, Object?> spec, String key) {
  final v = spec[key];
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is Map) {for (final x in e.entries) x.key.toString(): x.value},
  ];
}

class DescribeSpec {
  final String? label;
  final String? description;
  final List<String> examples;
  final String? unit;
  final String? owner;
  final String? deprecated;
  final Map<String, String> values;

  const DescribeSpec({
    this.label,
    this.description,
    this.examples = const [],
    this.unit,
    this.owner,
    this.deprecated,
    this.values = const {},
  });

  static const empty = DescribeSpec();

  factory DescribeSpec.fromJson(Map<String, Object?> spec) => DescribeSpec(
    label: specString(spec, 'label'),
    description: specString(spec, 'description'),
    examples: specStringList(spec, 'examples'),
    unit: specString(spec, 'unit'),
    owner: specString(spec, 'owner'),
    deprecated: specString(spec, 'deprecated'),
    values: {
      for (final e in specMap(spec, 'values').entries)
        if (e.value != null) e.key: e.value.toString(),
    },
  );

  bool get isEmpty =>
      label == null &&
      description == null &&
      examples.isEmpty &&
      unit == null &&
      owner == null &&
      deprecated == null &&
      values.isEmpty;

  /// Multi-line text for a tooltip. Empty when there is nothing to say.
  String toTooltip() {
    final lines = <String>[
      ?label,
      ?description,
      if (unit != null) 'Unit: $unit',
      if (owner != null) 'Owner: $owner',
      if (deprecated != null) 'Deprecated: $deprecated',
      if (examples.isNotEmpty) 'e.g. ${examples.join(', ')}',
    ];
    return lines.join('\n');
  }
}

/// Known value renderers for [DisplaySpec.renderer].
enum ValueRenderer {
  money,
  bytes,
  duration,
  timestamp,
  relativeTime,
  imageUrl,
  url,
  color,
  markdown,
  json
  ;

  static ValueRenderer? tryParse(Object? raw) {
    if (raw is! String) return null;
    final normalised = raw.trim().toLowerCase().replaceAll('_', '');
    for (final r in ValueRenderer.values) {
      if (r.name.toLowerCase() == normalised) return r;
    }
    return null;
  }
}

class DisplaySpec {
  final String? rowLabel;
  final List<String> order;
  final List<String> pinned;
  final String? defaultSort;
  final String? defaultFilter;
  final ValueRenderer? renderer;
  final Map<String, Object?> rendererArgs;
  final String? group;

  const DisplaySpec({
    this.rowLabel,
    this.order = const [],
    this.pinned = const [],
    this.defaultSort,
    this.defaultFilter,
    this.renderer,
    this.rendererArgs = const {},
    this.group,
  });

  static const empty = DisplaySpec();

  factory DisplaySpec.fromJson(Map<String, Object?> spec) => DisplaySpec(
    rowLabel: specString(spec, 'rowLabel'),
    order: specStringList(spec, 'order'),
    pinned: specStringList(spec, 'pinned'),
    defaultSort: specString(spec, 'defaultSort'),
    defaultFilter: specString(spec, 'defaultFilter'),
    renderer: ValueRenderer.tryParse(spec['renderer']),
    rendererArgs: specMap(spec, 'rendererArgs'),
    group: specString(spec, 'group'),
  );

  /// `"-created_at"` → (column: created_at, descending: true).
  ({String column, bool descending})? get parsedDefaultSort {
    final raw = defaultSort?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('-')) {
      return (column: raw.substring(1), descending: true);
    }
    return (column: raw, descending: false);
  }
}

class SensitiveSpec {
  final bool excludeFromAi;
  final bool excludeFromExport;
  const SensitiveSpec({
    this.excludeFromAi = false,
    this.excludeFromExport = false,
  });

  static const none = SensitiveSpec();

  factory SensitiveSpec.fromJson(Map<String, Object?> spec) => SensitiveSpec(
    excludeFromAi: specBool(spec, 'excludeFromAi'),
    excludeFromExport: specBool(spec, 'excludeFromExport'),
  );
}

class PolicySpec {
  final bool readOnly;
  final String? reason;
  final String? softDelete;
  final bool tenant;
  final List<String> touch;
  final String? pattern;
  final num? min;
  final num? max;
  final String? danger;
  final String? message;

  const PolicySpec({
    this.readOnly = false,
    this.reason,
    this.softDelete,
    this.tenant = false,
    this.touch = const [],
    this.pattern,
    this.min,
    this.max,
    this.danger,
    this.message,
  });

  static const empty = PolicySpec();

  factory PolicySpec.fromJson(Map<String, Object?> spec) => PolicySpec(
    readOnly: specBool(spec, 'readOnly'),
    reason: specString(spec, 'reason'),
    softDelete: specString(spec, 'softDelete'),
    tenant: specBool(spec, 'tenant'),
    touch: specStringList(spec, 'touch'),
    pattern: specString(spec, 'pattern'),
    min: specNum(spec, 'min'),
    max: specNum(spec, 'max'),
    danger: specString(spec, 'danger'),
    message: specString(spec, 'message'),
  );

  /// `danger: hardDelete` — refuse DELETE; a soft-delete column still works.
  bool get forbidsHardDelete => danger == 'hardDelete';

  /// `danger: delete` — refuse every delete, soft or hard (e.g. tables whose
  /// deletes must cascade through the app's own code path).
  bool get forbidsAnyDelete => danger == 'delete';
}

class AiExample {
  final String ask;
  final String sql;
  const AiExample(this.ask, this.sql);
}

class AiSpec {
  final String? notes;
  final List<AiExample> examples;
  const AiSpec({this.notes, this.examples = const []});

  factory AiSpec.fromJson(Map<String, Object?> spec) => AiSpec(
    notes: specString(spec, 'notes'),
    examples: [
      for (final e in specMapList(spec, 'examples'))
        if (specString(e, 'ask') != null && specString(e, 'sql') != null)
          AiExample(specString(e, 'ask')!, specString(e, 'sql')!),
    ],
  );
}

class RbacSettings {
  final AccessLevel defaultLevel;
  final IdentityMode identity;
  const RbacSettings({
    this.defaultLevel = AccessLevel.read,
    this.identity = IdentityMode.either,
  });

  factory RbacSettings.fromJson(Map<String, Object?> spec) => RbacSettings(
    defaultLevel: AccessLevel.tryParse(spec['default']) ?? AccessLevel.read,
    identity: IdentityMode.tryParse(spec['identity']) ?? IdentityMode.either,
  );
}

/// How a polymorphic link maps the kind column's value to a table name.
enum TableNameTransform {
  asIs,
  lower,
  upper
  ;

  static TableNameTransform? tryParse(Object? raw) => switch (raw) {
    'as_is' || 'asIs' => TableNameTransform.asIs,
    'lower' => TableNameTransform.lower,
    'upper' => TableNameTransform.upper,
    _ => null,
  };

  String apply(String value) => switch (this) {
    TableNameTransform.asIs => value,
    TableNameTransform.lower => value.toLowerCase(),
    TableNameTransform.upper => value.toUpperCase(),
  };
}

class LinkSpec {
  final String id;
  final Selector target;

  /// Plain virtual FK target (`schema.table.column`).
  final Selector? to;

  /// Polymorphic: the column in the same row that names the target.
  final String? polymorphicBy;
  final Map<String, Selector> polymorphicMap;
  final TableNameTransform? polymorphicTable;
  final String polymorphicColumn;

  /// Optional schema for polymorphic pattern targets; defaults to the
  /// source row's schema.
  final String? polymorphicSchema;

  /// JSON path inside the column (`$.template_id`) for ids stored in JSON.
  final String? jsonPath;

  /// External URL template (`{cell}`, `{row.<col>}`).
  final String? urlLabel;
  final String? urlTemplate;

  const LinkSpec({
    required this.id,
    required this.target,
    this.to,
    this.polymorphicBy,
    this.polymorphicMap = const {},
    this.polymorphicTable,
    this.polymorphicColumn = 'id',
    this.polymorphicSchema,
    this.jsonPath,
    this.urlLabel,
    this.urlTemplate,
  });

  factory LinkSpec.fromRow(MetaRow row) {
    final spec = row.spec;
    final poly = specMap(spec, 'polymorphic');
    final url = specMap(spec, 'url');
    final map = <String, Selector>{};
    for (final e in specMap(poly, 'map').entries) {
      final sel = e.value is String
          ? Selector.tryParse(e.value as String)
          : null;
      if (sel != null) map[e.key] = sel;
    }
    final toRaw = specString(spec, 'to');
    return LinkSpec(
      id: row.id,
      target: row.target,
      to: toRaw == null ? null : Selector.tryParse(toRaw),
      polymorphicBy: specString(poly, 'by'),
      polymorphicMap: map,
      polymorphicTable: TableNameTransform.tryParse(poly['table']),
      polymorphicColumn: specString(poly, 'column') ?? 'id',
      polymorphicSchema: specString(poly, 'schema'),
      jsonPath: specString(spec, 'jsonPath'),
      urlLabel: specString(url, 'label'),
      urlTemplate: specString(url, 'template'),
    );
  }

  bool get isUrl => urlTemplate != null;
  bool get isPolymorphic => polymorphicBy != null;
}

enum ActionScope {
  global,
  table,
  row,
  cell,
  selection
  ;

  static ActionScope? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final s in ActionScope.values) {
      if (s.name == raw) return s;
    }
    return null;
  }
}

enum ActionRun {
  query,
  openTable,
  exec,
  url,
  copy
  ;

  static ActionRun? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final r in ActionRun.values) {
      if (r.name == raw) return r;
    }
    return null;
  }

  /// Everything except `exec` only reads.
  bool get isReadOnly => this != ActionRun.exec;
}

class ActionInput {
  final String name;
  final String prompt;
  final String type;
  const ActionInput({
    required this.name,
    required this.prompt,
    this.type = 'text',
  });
}

class ActionSpec {
  final String id;
  final Selector target;
  final String label;
  final ActionScope scope;
  final ActionRun run;
  final String? group;
  final String? sql;
  final String? filter;
  final String? template;

  /// For `openTable`: which table to open (`schema.table`). Defaults to
  /// the target's own table.
  final Selector? table;
  final List<ActionInput> inputs;

  /// `{"row.kind": ["A", "B"]}` — shown only when every listed column's
  /// value is one of the listed values.
  final Map<String, List<String>> when;
  final String? confirm;
  final int? expectRows;
  final List<String> roles;

  const ActionSpec({
    required this.id,
    required this.target,
    required this.label,
    required this.scope,
    required this.run,
    this.group,
    this.sql,
    this.filter,
    this.template,
    this.table,
    this.inputs = const [],
    this.when = const {},
    this.confirm,
    this.expectRows,
    this.roles = const [],
  });

  static ActionSpec? fromRow(MetaRow row, List<MetaProblem> problems) {
    final spec = row.spec;
    final label = specString(spec, 'label');
    final scope = ActionScope.tryParse(spec['scope']);
    final run = ActionRun.tryParse(spec['run']);
    if (label == null || scope == null || run == null) {
      problems.add(
        MetaProblem(
          row.source,
          row.id,
          'An action needs label, scope (global|table|row|cell|selection) and '
          'run (query|openTable|exec|url|copy).',
        ),
      );
      return null;
    }
    final when = <String, List<String>>{};
    for (final e in specMap(spec, 'when').entries) {
      final v = e.value;
      if (v is List) {
        when[e.key] = [for (final x in v) x.toString()];
      } else if (v != null) {
        when[e.key] = [v.toString()];
      }
    }
    final tableRaw = specString(spec, 'table');
    return ActionSpec(
      id: row.id,
      target: row.target,
      label: label,
      scope: scope,
      run: run,
      group: specString(spec, 'group'),
      sql: specString(spec, 'sql'),
      filter: specString(spec, 'filter'),
      template: specString(spec, 'template') ?? specString(spec, 'url'),
      table: tableRaw == null ? null : Selector.tryParse(tableRaw),
      inputs: [
        for (final i in specMapList(spec, 'inputs'))
          if (specString(i, 'name') != null)
            ActionInput(
              name: specString(i, 'name')!,
              prompt: specString(i, 'prompt') ?? specString(i, 'name')!,
              type: specString(i, 'type') ?? 'text',
            ),
      ],
      when: when,
      confirm: specString(spec, 'confirm'),
      expectRows: specInt(spec, 'expectRows'),
      roles: specStringList(spec, 'roles'),
    );
  }
}

class NamedQuerySpec {
  /// The row id doubles as the query id (`query:<id>` in selectors).
  final String id;
  final String label;
  final String? description;
  final String sql;
  final List<ActionInput> inputs;
  final String? group;

  const NamedQuerySpec({
    required this.id,
    required this.label,
    this.description,
    required this.sql,
    this.inputs = const [],
    this.group,
  });

  static NamedQuerySpec? fromRow(MetaRow row, List<MetaProblem> problems) {
    final sql = specString(row.spec, 'sql');
    if (sql == null) {
      problems.add(MetaProblem(row.source, row.id, 'A query needs sql.'));
      return null;
    }
    return NamedQuerySpec(
      id: row.id,
      label: specString(row.spec, 'label') ?? row.id,
      description: specString(row.spec, 'description'),
      sql: sql,
      inputs: [
        for (final i in specMapList(row.spec, 'inputs'))
          if (specString(i, 'name') != null)
            ActionInput(
              name: specString(i, 'name')!,
              prompt: specString(i, 'prompt') ?? specString(i, 'name')!,
              type: specString(i, 'type') ?? 'text',
            ),
      ],
      group: specString(row.spec, 'group'),
    );
  }

  Selector get selector => Selector.tryParse(
    '${Selector.queryPrefix}${Selector.quote(id)}',
  )!;
}

enum ChartType {
  line,
  area,
  bar,
  stackedBar,
  pie,
  scatter,
  histogram,
  stat
  ;

  static ChartType? tryParse(Object? raw) {
    if (raw is! String) return null;
    final normalised = raw.trim().toLowerCase().replaceAll('_', '');
    for (final t in ChartType.values) {
      if (t.name.toLowerCase() == normalised) return t;
    }
    return null;
  }
}

enum ChartAggregate {
  count,
  sum,
  avg,
  min,
  max,
  countDistinct
  ;

  static ChartAggregate? tryParse(Object? raw) {
    if (raw is! String) return null;
    final normalised = raw.trim().toLowerCase().replaceAll('_', '');
    for (final a in ChartAggregate.values) {
      if (a.name.toLowerCase() == normalised) return a;
    }
    return null;
  }
}

enum ChartBucket {
  hour,
  day,
  week,
  month,
  year
  ;

  static ChartBucket? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final b in ChartBucket.values) {
      if (b.name == raw.trim().toLowerCase()) return b;
    }
    return null;
  }
}

enum ChartRange {
  last24Hours,
  last7Days,
  last30Days,
  last90Days,
  last365Days,
  all
  ;

  static ChartRange? tryParse(Object? raw) => switch (raw) {
    'last_24_hours' || 'last24Hours' => ChartRange.last24Hours,
    'last_7_days' || 'last7Days' => ChartRange.last7Days,
    'last_30_days' || 'last30Days' => ChartRange.last30Days,
    'last_90_days' || 'last90Days' => ChartRange.last90Days,
    'last_365_days' || 'last365Days' => ChartRange.last365Days,
    'all' => ChartRange.all,
    _ => null,
  };

  Duration? get duration => switch (this) {
    ChartRange.last24Hours => const Duration(hours: 24),
    ChartRange.last7Days => const Duration(days: 7),
    ChartRange.last30Days => const Duration(days: 30),
    ChartRange.last90Days => const Duration(days: 90),
    ChartRange.last365Days => const Duration(days: 365),
    ChartRange.all => null,
  };
}

class ChartMeasure {
  final ChartAggregate? aggregate;
  final String? column;
  final String? label;
  const ChartMeasure({this.aggregate, this.column, this.label});
}

/// Where a chart's data comes from.
sealed class ChartSource {
  const ChartSource();
}

/// A table; dbscope builds the aggregate SQL.
class ChartTableSource extends ChartSource {
  final String schema;
  final String table;
  const ChartTableSource(this.schema, this.table);
}

/// A named query.
class ChartQuerySource extends ChartSource {
  final String queryId;
  const ChartQuerySource(this.queryId);
}

/// Inline SQL (row-scoped charts bind `@row_<col>`).
class ChartSqlSource extends ChartSource {
  final String sql;
  const ChartSqlSource(this.sql);
}

class ChartSpec {
  static const int defaultTimeoutMs = 10000;
  static const int defaultLimit = 500;

  final String id;
  final Selector target;
  final String label;
  final ChartType type;
  final ChartSource source;
  final String? x;
  final ChartBucket? bucket;
  final List<ChartMeasure> y;
  final String? series;
  final ChartRange range;

  /// The time column `range` filters on. Defaults to [x] when x is
  /// time-bucketed; a chart whose x is categorical (e.g. a job name) must
  /// name its time column here for `range` to apply.
  final String? rangeColumn;
  final bool rowScoped;
  final int timeoutMs;
  final int limit;

  const ChartSpec({
    required this.id,
    required this.target,
    required this.label,
    required this.type,
    required this.source,
    this.x,
    this.bucket,
    this.y = const [],
    this.series,
    this.range = ChartRange.all,
    this.rangeColumn,
    this.rowScoped = false,
    this.timeoutMs = defaultTimeoutMs,
    this.limit = defaultLimit,
  });

  static ChartSpec? fromRow(MetaRow row, List<MetaProblem> problems) {
    final spec = row.spec;
    final type = ChartType.tryParse(spec['type']);
    if (type == null) {
      problems.add(
        MetaProblem(
          row.source,
          row.id,
          'A chart needs type (line|area|bar|stacked_bar|pie|scatter|'
          'histogram|stat).',
        ),
      );
      return null;
    }
    final sql = specString(spec, 'sql');
    final sourceRaw = specString(spec, 'source');
    ChartSource? source;
    if (sql != null) {
      source = ChartSqlSource(sql);
    } else if (sourceRaw != null) {
      final sel = Selector.tryParse(sourceRaw);
      final queryId = sel?.exactQueryId;
      final table = sel?.exactTable;
      if (queryId != null) {
        source = ChartQuerySource(queryId);
      } else if (table != null) {
        source = ChartTableSource(table.schema, table.table);
      }
    } else {
      final table = row.target.exactTable;
      final queryId = row.target.exactQueryId;
      if (queryId != null) {
        source = ChartQuerySource(queryId);
      } else if (table != null) {
        source = ChartTableSource(table.schema, table.table);
      }
    }
    if (source == null) {
      problems.add(
        MetaProblem(
          row.source,
          row.id,
          'A chart needs sql, or a source naming one table or query:<id>.',
        ),
      );
      return null;
    }
    final measures = <ChartMeasure>[
      for (final m in specMapList(spec, 'y'))
        ChartMeasure(
          aggregate: ChartAggregate.tryParse(m['agg']),
          column: specString(m, 'column'),
          label: specString(m, 'label'),
        ),
    ];
    return ChartSpec(
      id: row.id,
      target: row.target,
      label: specString(spec, 'label') ?? row.id,
      type: type,
      source: source,
      x: specString(spec, 'x'),
      bucket: ChartBucket.tryParse(spec['bucket']),
      y: measures.isEmpty
          ? const [ChartMeasure(aggregate: ChartAggregate.count)]
          : measures,
      series: specString(spec, 'series'),
      range: ChartRange.tryParse(spec['range']) ?? ChartRange.all,
      rangeColumn: specString(spec, 'rangeColumn'),
      rowScoped: specString(spec, 'scope') == 'row',
      timeoutMs: specInt(spec, 'timeoutMs') ?? defaultTimeoutMs,
      limit: specInt(spec, 'limit') ?? defaultLimit,
    );
  }
}

enum CheckSeverity {
  info,
  warning,
  error
  ;

  static CheckSeverity tryParse(Object? raw) => switch (raw) {
    'info' => CheckSeverity.info,
    'error' => CheckSeverity.error,
    _ => CheckSeverity.warning,
  };
}

class CheckSpec {
  final String id;
  final Selector target;
  final String label;
  final String sql;
  final CheckSeverity severity;
  final String? description;

  const CheckSpec({
    required this.id,
    required this.target,
    required this.label,
    required this.sql,
    this.severity = CheckSeverity.warning,
    this.description,
  });

  static CheckSpec? fromRow(MetaRow row, List<MetaProblem> problems) {
    final sql = specString(row.spec, 'sql');
    if (sql == null) {
      problems.add(MetaProblem(row.source, row.id, 'A check needs sql.'));
      return null;
    }
    return CheckSpec(
      id: row.id,
      target: row.target,
      label: specString(row.spec, 'label') ?? row.id,
      sql: sql,
      severity: CheckSeverity.tryParse(row.spec['severity']),
      description: specString(row.spec, 'description'),
    );
  }
}

class DashboardSpec {
  final String id;
  final String label;
  final List<String> chartIds;
  final int columns;

  const DashboardSpec({
    required this.id,
    required this.label,
    required this.chartIds,
    this.columns = 2,
  });

  factory DashboardSpec.fromRow(MetaRow row) => DashboardSpec(
    id: row.id,
    label: specString(row.spec, 'label') ?? row.id,
    chartIds: specStringList(row.spec, 'charts'),
    columns: (specInt(row.spec, 'columns') ?? 2).clamp(1, 4),
  );
}
