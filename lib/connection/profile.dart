import 'package:uuid/uuid.dart';

import '../meta/meta_settings.dart';

enum SslMode { disable, require, verifyFull }

final readOnlyHeuristic = RegExp(
  'prod|live|main',
  caseSensitive: false,
);

/// Built-in kind id for the direct-Postgres backend. External plugins
/// pick their own.
const kPostgresKind = 'postgres';

/// Per-profile default WHERE applied to every table that has the named
/// column. The canonical use is a multi-tenant `account_id = $X` scope:
/// a back-office user opens dbscope pinned to one account and the grid,
/// navigator, and FK navigation all stay within that tenant's data.
///
/// Tables that don't have [column] are not filtered (they're treated as
/// non-tenant-scoped). No exclude list — bypass is "use a Query tab".
class TenantFilter {
  const TenantFilter({required this.column, required this.value});
  final String column;
  final Object? value;

  Map<String, Object?> toJson() => {'column': column, 'value': value};

  static TenantFilter? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final column = raw['column'];
    if (column is! String || column.isEmpty) return null;
    return TenantFilter(column: column, value: raw['value']);
  }
}

/// Per-table opt-in behaviour. The map is keyed by `"schema.table"` on
/// [ConnectionProfile.tableOverrides]. Right now there's a single knob —
/// the soft-delete column — but the type exists so adding (e.g.) a label
/// column or a hidden-column list later is a non-breaking change.
class TableOverrides {
  const TableOverrides({this.softDeleteColumn});

  /// Column the app should write `now()` into instead of issuing a
  /// hard DELETE. The "Show deleted" toggle in the table view also keys
  /// off this — rows are filtered to `<col> IS NULL` by default when set.
  final String? softDeleteColumn;

  bool get isEmpty => softDeleteColumn == null;

  TableOverrides copyWith({Object? softDeleteColumn = _sentinel}) => TableOverrides(
    softDeleteColumn: identical(softDeleteColumn, _sentinel)
        ? this.softDeleteColumn
        : softDeleteColumn as String?,
  );

  Map<String, Object?> toJson() => {
    if (softDeleteColumn != null) 'softDeleteColumn': softDeleteColumn,
  };

  static TableOverrides? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final sdc = raw['softDeleteColumn'];
    final overrides = TableOverrides(
      softDeleteColumn: sdc is String && sdc.isNotEmpty ? sdc : null,
    );
    return overrides.isEmpty ? null : overrides;
  }
}

const _sentinel = Object();

class ConnectionProfile {
  ConnectionProfile({
    String? id,
    this.kind = kPostgresKind,
    required this.name,
    this.host = '',
    this.port = 5432,
    this.database = '',
    this.username = '',
    this.password = '',
    this.sslMode = SslMode.disable,
    bool? readOnly,
    Map<String, Object?>? extra,
    this.tenantFilter,
    Map<String, TableOverrides>? tableOverrides,
    this.metadata = MetadataSettings.defaults,
  }) : id = id ?? const Uuid().v4(),
       readOnly = readOnly ?? readOnlyHeuristic.hasMatch(name),
       extra = Map<String, Object?>.unmodifiable(extra ?? const {}),
       tableOverrides = Map<String, TableOverrides>.unmodifiable(
         tableOverrides ?? const {},
       );

  factory ConnectionProfile.fromJson(
    Map<String, Object?> json,
    String password,
  ) {
    final extraRaw = json['extra'];
    final overridesRaw = json['tableOverrides'];
    final overrides = <String, TableOverrides>{};
    if (overridesRaw is Map) {
      for (final entry in overridesRaw.entries) {
        final parsed = TableOverrides.fromJson(entry.value);
        if (parsed != null) {
          overrides[entry.key.toString()] = parsed;
        }
      }
    }
    return ConnectionProfile(
      id: json['id']! as String,
      kind: (json['kind'] as String?) ?? kPostgresKind,
      name: json['name']! as String,
      host: (json['host'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 5432,
      database: (json['database'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      password: password,
      sslMode: SslMode.values.firstWhere(
        (mode) => mode.name == (json['sslMode'] as String? ?? 'disable'),
        orElse: () => SslMode.disable,
      ),
      readOnly: json['readOnly'] as bool? ?? false,
      extra: extraRaw is Map<String, Object?>
          ? Map<String, Object?>.from(extraRaw)
          : extraRaw is Map
          ? extraRaw.map(
              (key, value) => MapEntry(key.toString(), value as Object?),
            )
          : const <String, Object?>{},
      tenantFilter: TenantFilter.fromJson(json['tenantFilter']),
      tableOverrides: overrides,
      metadata: MetadataSettings.fromJson(json['metadata']),
    );
  }

  final String id;

  /// Which ConnectionKindPlugin owns this profile.
  final String kind;
  final String name;
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final SslMode sslMode;
  final bool readOnly;

  /// Plugin-owned JSON blob persisted alongside the profile. The core
  /// reads/writes it opaquely; only the owning plugin interprets its
  /// shape. Use cases: environment URL, refresh-token fingerprint,
  /// last-known email, etc.
  final Map<String, Object?> extra;

  /// Optional default WHERE applied to every table that has the column.
  /// See [TenantFilter].
  final TenantFilter? tenantFilter;

  /// Per-table opt-in behaviour, keyed by `"schema.table"`. See
  /// [TableOverrides]. Empty by default.
  final Map<String, TableOverrides> tableOverrides;

  /// Where dbscope looks for schema metadata (tables and sidecar file).
  final MetadataSettings metadata;

  /// Lookup overrides for a specific table. Returns an empty
  /// [TableOverrides] (all fields null) when none are set so callers
  /// can do `profile.overridesFor(...).softDeleteColumn` without a null
  /// check at every site.
  TableOverrides overridesFor(String schema, String table) =>
      tableOverrides['$schema.$table'] ?? const TableOverrides();

  ConnectionProfile copyWith({
    String? kind,
    String? name,
    String? host,
    int? port,
    String? database,
    String? username,
    String? password,
    SslMode? sslMode,
    bool? readOnly,
    Map<String, Object?>? extra,
    Object? tenantFilter = _sentinel,
    Map<String, TableOverrides>? tableOverrides,
    MetadataSettings? metadata,
  }) => ConnectionProfile(
    id: id,
    kind: kind ?? this.kind,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    database: database ?? this.database,
    username: username ?? this.username,
    password: password ?? this.password,
    sslMode: sslMode ?? this.sslMode,
    readOnly: readOnly ?? this.readOnly,
    extra: extra ?? this.extra,
    tenantFilter: identical(tenantFilter, _sentinel)
        ? this.tenantFilter
        : tenantFilter as TenantFilter?,
    tableOverrides: tableOverrides ?? this.tableOverrides,
    metadata: metadata ?? this.metadata,
  );

  /// Replace the overrides for one table key. Passing null removes the
  /// entry entirely so the profile JSON stays small.
  ConnectionProfile withTableOverride(
    String schema,
    String table,
    TableOverrides? overrides,
  ) {
    final key = '$schema.$table';
    final next = Map<String, TableOverrides>.from(tableOverrides);
    if (overrides == null || overrides.isEmpty) {
      next.remove(key);
    } else {
      next[key] = overrides;
    }
    return copyWith(tableOverrides: next);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'host': host,
    'port': port,
    'database': database,
    'username': username,
    'sslMode': sslMode.name,
    'readOnly': readOnly,
    'extra': extra,
    if (tenantFilter != null) 'tenantFilter': tenantFilter!.toJson(),
    if (tableOverrides.isNotEmpty)
      'tableOverrides': {
        for (final e in tableOverrides.entries) e.key: e.value.toJson(),
      },
    if (!metadata.isDefault) 'metadata': metadata.toJson(),
  };
}
