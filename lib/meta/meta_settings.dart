// Per-profile metadata settings, persisted on the connection profile.

/// Whether dbscope looks for metadata tables in the database.
enum MetaTablesMode {
  /// Use `dbscope.*` (Postgres) / `_dbscope_*` (SQLite) when present.
  auto,

  /// Use a custom schema name (Postgres) or table prefix (SQLite).
  custom,

  /// Never read metadata tables. The sidecar file still applies.
  off
  ;

  static MetaTablesMode parse(Object? raw) {
    for (final m in MetaTablesMode.values) {
      if (m.name == raw) return m;
    }
    return MetaTablesMode.auto;
  }
}

/// Default Postgres schema for the metadata tables.
const String kDefaultMetaSchema = 'dbscope';

/// Default SQLite table prefix for the metadata tables.
const String kDefaultMetaTablePrefix = '_dbscope_';

class MetadataSettings {
  final MetaTablesMode tablesMode;

  /// Postgres schema name, or SQLite table prefix, when [tablesMode] is
  /// [MetaTablesMode.custom].
  final String? customName;

  /// Path of the sidecar YAML/JSON file, or null for none.
  final String? sidecarPath;

  /// The identity this user claims on this connection (an email), matched
  /// against `user:<email>` role members. Claimed identity only ever gives
  /// guardrails — see plan.md "Identity". Stored on the profile (not in
  /// SharedPreferences) so every window resolves the same roles.
  final String? claimedIdentity;

  const MetadataSettings({
    this.tablesMode = MetaTablesMode.auto,
    this.customName,
    this.sidecarPath,
    this.claimedIdentity,
  });

  static const defaults = MetadataSettings();

  bool get isDefault =>
      tablesMode == MetaTablesMode.auto &&
      customName == null &&
      sidecarPath == null &&
      claimedIdentity == null;

  /// Postgres schema the tables live in.
  String get postgresSchema =>
      tablesMode == MetaTablesMode.custom && (customName ?? '').isNotEmpty
      ? customName!
      : kDefaultMetaSchema;

  /// SQLite table-name prefix.
  String get sqlitePrefix =>
      tablesMode == MetaTablesMode.custom && (customName ?? '').isNotEmpty
      ? customName!
      : kDefaultMetaTablePrefix;

  MetadataSettings copyWith({
    MetaTablesMode? tablesMode,
    Object? customName = _unset,
    Object? sidecarPath = _unset,
    Object? claimedIdentity = _unset,
  }) => MetadataSettings(
    tablesMode: tablesMode ?? this.tablesMode,
    customName: identical(customName, _unset)
        ? this.customName
        : customName as String?,
    sidecarPath: identical(sidecarPath, _unset)
        ? this.sidecarPath
        : sidecarPath as String?,
    claimedIdentity: identical(claimedIdentity, _unset)
        ? this.claimedIdentity
        : claimedIdentity as String?,
  );

  Map<String, Object?> toJson() => {
    'tablesMode': tablesMode.name,
    if (customName != null) 'customName': customName,
    if (sidecarPath != null) 'sidecarPath': sidecarPath,
    if (claimedIdentity != null) 'claimedIdentity': claimedIdentity,
  };

  static MetadataSettings fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    String? text(Object? v) =>
        v is String && v.trim().isNotEmpty ? v.trim() : null;
    return MetadataSettings(
      tablesMode: MetaTablesMode.parse(raw['tablesMode']),
      customName: text(raw['customName']),
      sidecarPath: text(raw['sidecarPath']),
      claimedIdentity: text(raw['claimedIdentity']),
    );
  }
}

const Object _unset = Object();
