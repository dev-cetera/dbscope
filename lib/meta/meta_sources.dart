// The four metadata sources. Each produces a MetaSourceData; the cache
// merges them with mergeMetaSources (lowest precedence first).

import 'package:yaml/yaml.dart';

import '../connection/profile.dart';
import '../db/executor.dart';
import '../db/sqlite_kind.dart';
import '../util/portable_io.dart';
import '../util/sql_parse.dart';
import '../util/sql_quote.dart';
import 'meta_models.dart';
import 'meta_parse.dart';
import 'meta_settings.dart';
import 'selector.dart';

bool isSqliteExecutor(DbExecutor executor) => executor.kind == kSqliteKind;

SqlDialect sqlDialectOf(DbExecutor executor) =>
    isSqliteExecutor(executor) ? SqlDialect.sqlite : SqlDialect.postgres;

/// Native catalog comments: Postgres `COMMENT ON TABLE/COLUMN`. SQLite has
/// no comments, so it contributes nothing there.
class NativeCommentSource {
  static Future<MetaSourceData> load(DbExecutor executor) async {
    final builder = MetaSourceBuilder(MetaSourceKind.native);
    if (isSqliteExecutor(executor)) return builder.build();
    try {
      final result = await executor.execute('''
 SELECT n.nspname, c.relname, a.attname, d.description
 FROM pg_description d
 JOIN pg_class c ON c.oid = d.objoid
 JOIN pg_namespace n ON n.oid = c.relnamespace
 LEFT JOIN pg_attribute a
 ON a.attrelid = c.oid AND a.attnum = d.objsubid AND d.objsubid > 0
 WHERE d.classoid = 'pg_class'::regclass
 AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
 AND n.nspname NOT IN ('pg_catalog', 'information_schema')
 ''');
      for (final row in result.rows) {
        final schema = row[0]! as String;
        final table = row[1]! as String;
        final column = row[2] as String?;
        final description = row[3] as String?;
        if (description == null || description.trim().isEmpty) continue;
        final target = column == null
            ? Selector.forTable(schema, table)
            : Selector.forColumn(schema, table, column);
        builder.rows.add(
          MetaRow(
            id: 'native:${target.raw}',
            target: target,
            kind: MetaKinds.describe,
            spec: {'description': description.trim()},
            source: MetaSourceKind.native,
          ),
        );
      }
      // Schema comments describe the schema row in the sidebar.
      final schemas = await executor.execute(r'''
 SELECT n.nspname, obj_description(n.oid, 'pg_namespace')
 FROM pg_namespace n
 WHERE obj_description(n.oid, 'pg_namespace') IS NOT NULL
 AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
 ''');
      for (final row in schemas.rows) {
        final schema = row[0]! as String;
        final description = (row[1] as String?)?.trim();
        if (description == null || description.isEmpty) continue;
        builder.rows.add(
          MetaRow(
            id: 'native-schema:$schema',
            target: Selector.tryParse(Selector.quote(schema))!,
            kind: MetaKinds.describe,
            spec: {'description': description},
            source: MetaSourceKind.native,
          ),
        );
      }
      // A comment on a type (an enum, a domain) describes every column of
      // that type. Lower priority, so the column's own comment wins.
      final types = await executor.execute('''
 SELECT n.nspname, c.relname, a.attname, format_type(t.oid, NULL),
 obj_description(t.oid, 'pg_type')
 FROM pg_attribute a
 JOIN pg_class c ON c.oid = a.attrelid
 JOIN pg_namespace n ON n.oid = c.relnamespace
 JOIN pg_type t ON t.oid = a.atttypid
 WHERE a.attnum > 0 AND NOT a.attisdropped
 AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
 AND n.nspname NOT IN ('pg_catalog', 'information_schema')
 AND obj_description(t.oid, 'pg_type') IS NOT NULL
 ''');
      for (final row in types.rows) {
        final target = Selector.forColumn(
          row[0]! as String,
          row[1]! as String,
          row[2]! as String,
        );
        builder.rows.add(
          MetaRow(
            id: 'native-type:${target.raw}',
            target: target,
            kind: MetaKinds.describe,
            spec: {'description': '${row[3]}: ${(row[4]! as String).trim()}'},
            priority: -1,
            source: MetaSourceKind.native,
          ),
        );
      }
    } catch (e) {
      builder.problems.add(
        MetaProblem(
          MetaSourceKind.native,
          'pg_description',
          'Could not read COMMENT ON descriptions: $e',
        ),
      );
    }
    return builder.build();
  }
}

/// Outcome of looking for the metadata tables. "Unreadable" is distinct
/// from "absent" on purpose: unreadable rules must fail closed.
enum MetaTablesOutcome { off, absent, loaded, unreadable }

class MetaTablesResult {
  const MetaTablesResult(this.outcome, this.data, {this.error});
  final MetaTablesOutcome outcome;
  final MetaSourceData data;
  final String? error;
}

/// Physical names of the four metadata tables for one connection.
class MetaTableNames {
  const MetaTableNames({
    required this.meta,
    required this.roles,
    required this.members,
    required this.grants,
    this.schema,
  });

  factory MetaTableNames.forExecutor(
    DbExecutor executor,
    MetadataSettings settings,
  ) {
    final sqlite = isSqliteExecutor(executor);
    String name(String logicalName) =>
        physical(logicalName, settings, sqlite: sqlite);
    if (sqlite) {
      return MetaTableNames(
        meta: quoteIdent(name(metadata)),
        roles: quoteIdent(name(accessRoles)),
        members: quoteIdent(name(accessRoleMembers)),
        grants: quoteIdent(name(accessGrants)),
      );
    }
    final schema = settings.postgresSchema;
    return MetaTableNames(
      meta: quoteQualified(schema, name(metadata)),
      roles: quoteQualified(schema, name(accessRoles)),
      members: quoteQualified(schema, name(accessRoleMembers)),
      grants: quoteQualified(schema, name(accessGrants)),
      schema: schema,
    );
  }
  final String meta;
  final String roles;
  final String members;
  final String grants;

  /// Postgres schema holding them (null on SQLite).
  final String? schema;

  static const metadata = 'metadata';
  static const accessRoles = 'access_roles';
  static const accessRoleMembers = 'access_role_members';
  static const accessGrants = 'access_grants';

  /// The four logical table names, in creation order.
  static const List<String> logical = [
    metadata,
    accessRoles,
    accessRoleMembers,
    accessGrants,
  ];

  /// Every Postgres metadata table carries this prefix, so it reads as
  /// dbscope's own wherever it shows up — a bare `roles` or `grants` could
  /// be the application's own access control.
  static const postgresTablePrefix = 'dbscope_';

  /// The real table name of [logicalName]: `dbscope_<name>` on Postgres
  /// (inside the metadata schema), `<prefix><name>` on SQLite.
  static String physical(
    String logicalName,
    MetadataSettings settings, {
    required bool sqlite,
  }) => sqlite
      ? '${settings.sqlitePrefix}$logicalName'
      : '$postgresTablePrefix$logicalName';

  /// Is [schema].[table] exactly one of dbscope's own four tables? Exact
  /// names only: a prefix or schema match would also hide user tables that
  /// merely share a custom prefix (`messages` under prefix `m`) or live in
  /// the same schema (metadata tables in `public`).
  static bool isMetaTable(
    String schema,
    String table,
    MetadataSettings settings, {
    required bool sqlite,
  }) {
    final isOurs = logical.any(
      (logicalName) => table == physical(logicalName, settings, sqlite: sqlite),
    );
    if (sqlite) return isOurs;
    return schema == settings.postgresSchema && isOurs;
  }

  /// Whether the whole metadata schema may be hidden from non-managers:
  /// only a dedicated schema, never `public`.
  static bool isDedicatedMetaSchema(String schema, MetadataSettings settings) =>
      schema == settings.postgresSchema && schema != 'public';
}

class DbTableSource {
  static Future<MetaTablesResult> load(
    DbExecutor executor,
    MetadataSettings settings,
  ) async {
    final builder = MetaSourceBuilder(MetaSourceKind.database);
    if (settings.tablesMode == MetaTablesMode.off) {
      return MetaTablesResult(MetaTablesOutcome.off, builder.build());
    }
    final names = MetaTableNames.forExecutor(executor, settings);

    // Detection. Presence is decided by the catalog, so a permissions
    // problem on the tables themselves shows up as "unreadable", not
    // "absent".
    final Set<String> present;
    try {
      present = await _presentTables(executor, settings);
    } catch (e) {
      return MetaTablesResult(
        MetaTablesOutcome.unreadable,
        builder.build(),
        error: 'Could not check for metadata tables: $e',
      );
    }
    if (present.isEmpty) {
      return MetaTablesResult(MetaTablesOutcome.absent, builder.build());
    }

    try {
      if (present.contains(MetaTableNames.metadata)) {
        final result = await executor.execute(
          'SELECT id, target, kind, spec, priority, enabled FROM ${names.meta}',
        );
        for (final row in result.rows) {
          builder.addMetaEntry({
            'id': row[0],
            'target': row[1],
            'kind': row[2],
            'spec': row[3],
            'priority': row[4],
            'enabled': row[5],
          }, where: names.meta);
        }
      }
      if (present.contains(MetaTableNames.accessRoles)) {
        final result = await executor.execute(
          'SELECT id, label, description, inherits, capabilities, db_role, spec '
          'FROM ${names.roles}',
        );
        for (final row in result.rows) {
          builder.addRole({
            'id': row[0],
            'label': row[1],
            'description': row[2],
            'inherits': row[3],
            'capabilities': row[4],
            'db_role': row[5],
            'spec': row[6],
          }, where: names.roles);
        }
      }
      if (present.contains(MetaTableNames.accessRoleMembers)) {
        final result = await executor.execute(
          'SELECT role_id, principal FROM ${names.members}',
        );
        for (final row in result.rows) {
          builder.addMember({
            'role_id': row[0],
            'principal': row[1],
          }, where: names.members);
        }
      }
      if (present.contains(MetaTableNames.accessGrants)) {
        final result = await executor.execute(
          'SELECT id, role_id, target, level, default_hidden, note, enabled, spec '
          'FROM ${names.grants}',
        );
        for (final row in result.rows) {
          builder.addGrant({
            'id': row[0],
            'role_id': row[1],
            'target': row[2],
            'level': row[3],
            'default_hidden': row[4],
            'note': row[5],
            'enabled': row[6],
            'spec': row[7],
          }, where: names.grants);
        }
      }
    } catch (e) {
      return MetaTablesResult(
        MetaTablesOutcome.unreadable,
        builder.build(),
        error: 'Metadata tables exist but could not be read: $e',
      );
    }
    return MetaTablesResult(MetaTablesOutcome.loaded, builder.build());
  }

  static Future<Set<String>> _presentTables(
    DbExecutor executor,
    MetadataSettings settings,
  ) async {
    final sqlite = isSqliteExecutor(executor);
    // Physical name → logical name.
    final byPhysical = {
      for (final logicalName in MetaTableNames.logical)
        MetaTableNames.physical(logicalName, settings, sqlite: sqlite):
            logicalName,
    };
    if (sqlite) {
      final result = await executor.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN "
        '(?1, ?2, ?3, ?4)',
        positional: byPhysical.keys.toList(),
      );
      return {for (final row in result.rows) ?byPhysical[row[0]! as String]};
    }
    // The names are our own constants, so listing them inline is safe.
    final inList = byPhysical.keys
        .map((physicalName) => "'$physicalName'")
        .join(', ');
    final result = await executor.execute(
      '''
 SELECT c.relname
 FROM pg_class c
 JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = @schema
 AND c.relname IN ($inList)
 AND c.relkind IN ('r', 'v', 'p')
 ''',
      named: {'schema': settings.postgresSchema},
    );
    return {for (final row in result.rows) ?byPhysical[row[0]! as String]};
  }
}

/// The sidecar YAML/JSON file, with `include:` resolved relative to the
/// including file. Includes load first, so the including file wins.
class FileSource {
  static const _maxIncludeDepth = 8;

  static Future<MetaSourceData> load(String path) async {
    final builder = MetaSourceBuilder(MetaSourceKind.file);
    await _loadInto(builder, path, <String>{}, 0);
    return builder.build();
  }

  /// Parses text directly (used by tests and by "Import metadata file").
  static MetaSourceData parseText(String text, {String where = 'text'}) {
    final builder = MetaSourceBuilder(MetaSourceKind.file);
    final document = _decode(text, builder, where);
    if (document != null) builder.addDocument(document, where: where);
    return builder.build();
  }

  static Future<void> _loadInto(
    MetaSourceBuilder builder,
    String path,
    Set<String> visiting,
    int depth,
  ) async {
    if (visiting.contains(path)) {
      builder.problems.add(
        MetaProblem(MetaSourceKind.file, path, 'Include cycle — skipped.'),
      );
      return;
    }
    if (depth > _maxIncludeDepth) {
      builder.problems.add(
        MetaProblem(MetaSourceKind.file, path, 'Includes nest too deeply.'),
      );
      return;
    }
    final String text;
    try {
      text = await readTextFile(path);
    } catch (e) {
      builder.problems.add(
        MetaProblem(MetaSourceKind.file, path, 'Could not read file: $e'),
      );
      return;
    }
    final document = _decode(text, builder, path);
    if (document == null) return;
    visiting.add(path);
    final directory = parentDirectory(path);
    for (final include in decodeStringListCell(document['include'])) {
      await _loadInto(
        builder,
        resolveRelativePath(directory, include),
        visiting,
        depth + 1,
      );
    }
    visiting.remove(path);
    builder.addDocument(document, where: path);
  }

  static Map<String, Object?>? _decode(
    String text,
    MetaSourceBuilder builder,
    String where,
  ) {
    try {
      final decoded = plainJson(loadYaml(text));
      if (decoded == null) return const {};
      if (decoded is Map<String, Object?>) return decoded;
      builder.problems.add(
        MetaProblem(MetaSourceKind.file, where, 'Top level must be a map.'),
      );
    } catch (e) {
      builder.problems.add(
        MetaProblem(MetaSourceKind.file, where, 'Not valid YAML/JSON: $e'),
      );
    }
    return null;
  }
}

/// This machine's per-profile overrides, expressed as metadata so they
/// take part in the same precedence rules (they sit on top).
class ProfileOverrideSource {
  static MetaSourceData fromProfile(ConnectionProfile profile) {
    final rows = <MetaRow>[];
    for (final entry in profile.tableOverrides.entries) {
      final column = entry.value.softDeleteColumn;
      final dot = entry.key.indexOf('.');
      if (column == null || dot < 0) continue;
      final schema = entry.key.substring(0, dot);
      final table = entry.key.substring(dot + 1);
      rows.add(
        MetaRow(
          id: 'profile:${entry.key}:softDelete',
          target: Selector.forTable(schema, table),
          kind: MetaKinds.policy,
          spec: {'softDelete': column},
          source: MetaSourceKind.profile,
        ),
      );
    }
    return MetaSourceData(source: MetaSourceKind.profile, rows: rows);
  }
}
