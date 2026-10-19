// Writes to the metadata tables (and Postgres comments). Used by "Edit
// description…", "Initialize metadata tables…" and "Import metadata file".
// Everything goes through parameters; identifiers through quoteIdent.

import 'dart:convert';

import '../db/executor.dart';
import '../util/sql_quote.dart';
import 'meta_models.dart';
import 'meta_settings.dart';
import 'meta_sources.dart';

class MetaWriter {
  MetaWriter(this.executor, this.settings);
  final DbExecutor executor;
  final MetadataSettings settings;

  bool get _sqlite => isSqliteExecutor(executor);
  MetaTableNames get _names => MetaTableNames.forExecutor(executor, settings);

  /// DDL that creates the four metadata tables, for the "Initialize…"
  /// preview. Idempotent (`IF NOT EXISTS`).
  String createTablesSql() {
    if (_sqlite) {
      final tableNames = _names;
      return '''
CREATE TABLE IF NOT EXISTS ${tableNames.meta} (
  id TEXT PRIMARY KEY,
  target TEXT NOT NULL DEFAULT '*',
  kind TEXT NOT NULL,
  spec TEXT NOT NULL DEFAULT '{}',
  priority INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS ${tableNames.roles} (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  description TEXT,
  inherits TEXT NOT NULL DEFAULT '[]',
  capabilities TEXT NOT NULL DEFAULT '[]',
  db_role TEXT,
  spec TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS ${tableNames.members} (
  role_id TEXT NOT NULL REFERENCES ${tableNames.roles}(id) ON DELETE CASCADE,
  principal TEXT NOT NULL,
  PRIMARY KEY (role_id, principal)
);
CREATE TABLE IF NOT EXISTS ${tableNames.grants} (
  id TEXT PRIMARY KEY,
  role_id TEXT NOT NULL REFERENCES ${tableNames.roles}(id) ON DELETE CASCADE,
  target TEXT NOT NULL,
  level TEXT NOT NULL CHECK (level IN ('none', 'masked', 'read', 'edit', 'full')),
  default_hidden INTEGER NOT NULL DEFAULT 0,
  note TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  spec TEXT NOT NULL DEFAULT '{}'
);''';
    }
    final schema = quoteIdent(settings.postgresSchema);
    final tableNames = _names;
    return '''
CREATE SCHEMA IF NOT EXISTS $schema;
CREATE TABLE IF NOT EXISTS ${tableNames.meta} (
  id TEXT PRIMARY KEY,
  target TEXT NOT NULL DEFAULT '*',
  kind TEXT NOT NULL,
  spec JSONB NOT NULL DEFAULT '{}',
  priority INT NOT NULL DEFAULT 0,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS ${tableNames.roles} (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  description TEXT,
  inherits JSONB NOT NULL DEFAULT '[]',
  capabilities JSONB NOT NULL DEFAULT '[]',
  db_role TEXT,
  spec JSONB NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS ${tableNames.members} (
  role_id TEXT NOT NULL REFERENCES ${tableNames.roles}(id) ON DELETE CASCADE,
  principal TEXT NOT NULL,
  PRIMARY KEY (role_id, principal)
);
CREATE TABLE IF NOT EXISTS ${tableNames.grants} (
  id TEXT PRIMARY KEY,
  role_id TEXT NOT NULL REFERENCES ${tableNames.roles}(id) ON DELETE CASCADE,
  target TEXT NOT NULL,
  level TEXT NOT NULL CHECK (level IN ('none', 'masked', 'read', 'edit', 'full')),
  default_hidden BOOLEAN NOT NULL DEFAULT FALSE,
  note TEXT,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  spec JSONB NOT NULL DEFAULT '{}'
);
COMMENT ON SCHEMA $schema IS 'dbscope (database viewer) metadata: descriptions, display, queries, charts and viewer access rules. Not used by the application.';
COMMENT ON TABLE ${tableNames.meta} IS 'dbscope: schema metadata rows (display, links, actions, named queries, charts, checks, AI notes).';
COMMENT ON TABLE ${tableNames.roles} IS 'dbscope: roles for what the database VIEWER shows each person. Not the application''s roles.';
COMMENT ON TABLE ${tableNames.members} IS 'dbscope: who holds which viewer role (user:<email> or pg:<role>).';
COMMENT ON TABLE ${tableNames.grants} IS 'dbscope: what each viewer role may see or edit (none / masked / read / edit / full).';
-- Everyone must be able to READ the rules (the client applies them);
-- grant writes only to the people who manage them.
GRANT USAGE ON SCHEMA $schema TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA $schema TO PUBLIC;
INSERT INTO ${tableNames.meta} (id, target, kind, spec)
VALUES ('format', '*', 'format', '{"version": 1}')
ON CONFLICT (id) DO NOTHING;''';
  }

  /// Runs [createTablesSql] statement by statement (the executors run one
  /// statement per call).
  Future<void> createTables() async {
    for (final statement in splitStatements(createTablesSql())) {
      await executor.execute(statement);
    }
    if (_sqlite) {
      await executor.execute(
        'INSERT OR IGNORE INTO ${_names.meta} (id, target, kind, spec) '
        "VALUES ('format', '*', 'format', '{\"version\": 1}')",
      );
    }
  }

  Future<void> upsertMetaRow({
    required String id,
    required String target,
    required String kind,
    required Map<String, Object?> spec,
    int priority = 0,
  }) async {
    final params = {
      'id': id,
      'target': target,
      'kind': kind,
      'spec': jsonEncode(spec),
      'priority': priority,
    };
    if (_sqlite) {
      await executor.execute(
        'INSERT OR REPLACE INTO ${_names.meta} (id, target, kind, spec, priority) '
        'VALUES (@id, @target, @kind, @spec, @priority)',
        named: params,
      );
      return;
    }
    await executor.execute(
      'INSERT INTO ${_names.meta} (id, target, kind, spec, priority) '
      'VALUES (@id, @target, @kind, CAST(@spec AS jsonb), @priority) '
      'ON CONFLICT (id) DO UPDATE SET target = EXCLUDED.target, '
      'kind = EXCLUDED.kind, spec = EXCLUDED.spec, '
      'priority = EXCLUDED.priority, enabled = TRUE, updated_at = now()',
      named: params,
    );
  }

  /// `COMMENT ON COLUMN/TABLE` (Postgres only), so psql `\d+`, pg_dump and
  /// other tools see the description too.
  Future<void> writeComment({
    required String schema,
    required String table,
    String? column,
    required String text,
  }) async {
    if (_sqlite) return;
    final target = column == null
        ? 'TABLE ${quoteQualified(schema, table)}'
        : 'COLUMN ${quoteQualified(schema, table)}.${quoteIdent(column)}';
    // COMMENT ON takes a literal, not a parameter.
    await executor.execute('COMMENT ON $target IS ${quoteLiteral(text)}');
  }

  /// Replaces the database copy with [data] (from a metadata file):
  /// upserts every row, role, member and grant. Rows not in the file are
  /// left alone.
  Future<int> importSource(MetaSourceData data) async {
    var count = 0;
    for (final row in data.rows) {
      await upsertMetaRow(
        id: row.id,
        target: row.target.raw,
        kind: row.kind,
        spec: row.spec,
        priority: row.priority,
      );
      count++;
    }
    final tableNames = _names;
    String json(String param) => _sqlite ? '@$param' : 'CAST(@$param AS jsonb)';
    for (final role in data.roles) {
      final params = {
        'id': role.id,
        'label': role.label,
        'description': role.description,
        'inherits': jsonEncode(role.inherits),
        'capabilities': jsonEncode([
          for (final capability in role.capabilities) capability.name,
        ]),
        'db_role': role.dbRole,
      };
      // An upsert on both backends: SQLite's INSERT OR REPLACE would DELETE
      // the old row first, and ON DELETE CASCADE would take the role's
      // members and grants with it.
      await executor.execute(
        'INSERT INTO ${tableNames.roles} '
        '(id, label, description, inherits, capabilities, db_role) VALUES '
        '(@id, @label, @description, ${json('inherits')}, '
        '${json('capabilities')}, @db_role) '
        'ON CONFLICT (id) DO UPDATE SET label = EXCLUDED.label, '
        'description = EXCLUDED.description, inherits = EXCLUDED.inherits, '
        'capabilities = EXCLUDED.capabilities, db_role = EXCLUDED.db_role',
        named: params,
      );
      count++;
    }
    // Roles referenced only by members/grants must exist for the FK.
    final referenced = {
      for (final member in data.members) member.roleId,
      for (final grant in data.grants) grant.roleId,
    }.difference({for (final role in data.roles) role.id});
    for (final id in referenced) {
      await executor.execute(
        _sqlite
            ? 'INSERT OR IGNORE INTO ${tableNames.roles} (id, label) VALUES (@id, @id)'
            : 'INSERT INTO ${tableNames.roles} (id, label) VALUES (@id, @id) '
                  'ON CONFLICT (id) DO NOTHING',
        named: {'id': id},
      );
    }
    for (final member in data.members) {
      await executor.execute(
        _sqlite
            ? 'INSERT OR IGNORE INTO ${tableNames.members} (role_id, principal) '
                  'VALUES (@role_id, @principal)'
            : 'INSERT INTO ${tableNames.members} (role_id, principal) '
                  'VALUES (@role_id, @principal) ON CONFLICT DO NOTHING',
        named: {'role_id': member.roleId, 'principal': member.principal},
      );
      count++;
    }
    for (final grant in data.grants) {
      final params = {
        'id': grant.id,
        'role_id': grant.roleId,
        'target': grant.target.raw,
        'level': grant.level.name,
        'default_hidden': _sqlite ? (grant.defaultHidden ? 1 : 0) : grant.defaultHidden,
        'note': grant.note,
      };
      await executor.execute(
        _sqlite
            ? 'INSERT OR REPLACE INTO ${tableNames.grants} '
                  '(id, role_id, target, level, default_hidden, note) VALUES '
                  '(@id, @role_id, @target, @level, @default_hidden, @note)'
            : 'INSERT INTO ${tableNames.grants} '
                  '(id, role_id, target, level, default_hidden, note) VALUES '
                  '(@id, @role_id, @target, @level, @default_hidden, @note) '
                  'ON CONFLICT (id) DO UPDATE SET role_id = EXCLUDED.role_id, '
                  'target = EXCLUDED.target, level = EXCLUDED.level, '
                  'default_hidden = EXCLUDED.default_hidden, '
                  'note = EXCLUDED.note, enabled = TRUE',
        named: params,
      );
      count++;
    }
    for (final id in data.disabledRowIds) {
      await executor.execute(
        'DELETE FROM ${tableNames.meta} WHERE id = @id',
        named: {'id': id},
      );
    }
    for (final id in data.disabledGrantIds) {
      await executor.execute(
        'DELETE FROM ${tableNames.grants} WHERE id = @id',
        named: {'id': id},
      );
    }
    return count;
  }
}

/// Splits a script on top-level semicolons (outside quotes and comments).
List<String> splitStatements(String script) {
  final out = <String>[];
  final current = StringBuffer();
  var i = 0;
  String? quote;
  while (i < script.length) {
    final ch = script[i];
    if (quote != null) {
      current.write(ch);
      if (ch == quote) quote = null;
      i++;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      current.write(ch);
      i++;
      continue;
    }
    if (ch == '-' && i + 1 < script.length && script[i + 1] == '-') {
      final end = script.indexOf('\n', i);
      i = end < 0 ? script.length : end;
      continue;
    }
    if (ch == ';') {
      final text = current.toString().trim();
      if (text.isNotEmpty) out.add(text);
      current.clear();
      i++;
      continue;
    }
    current.write(ch);
    i++;
  }
  final tail = current.toString().trim();
  if (tail.isNotEmpty) out.add(tail);
  return out;
}

/// The id a describe row written from the UI gets.
/// Uses the quoted selector form, so `"a.b".c` and `a.b.c` stay distinct.
String describeRowId(String schema, String table, [String? column]) =>
    'describe:${describeTarget(schema, table, column)}';

/// Selector raw text for a table/column written from the UI.
String describeTarget(String schema, String table, [String? column]) {
  final base = '${_q(schema)}.${_q(table)}';
  return column == null ? base : '$base.${_q(column)}';
}

String _q(String name) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name) ? name : '"${name.replaceAll('"', '""')}"';
