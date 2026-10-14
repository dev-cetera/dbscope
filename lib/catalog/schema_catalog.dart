import '../db/executor.dart';
import '../db/sqlite_kind.dart';
import '../meta/access_policy.dart';
import '../meta/masked_value.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../meta/meta_sources.dart';
import '../util/db_coerce.dart';
import '../util/sql_quote.dart';
import 'pg_type.dart';

class SchemaInfo {
  const SchemaInfo(this.name, {required this.isSystem});
  final String name;
  final bool isSystem;
}

class TableInfo {
  const TableInfo({
    required this.schema,
    required this.name,
    required this.kind,
    required this.estimatedRows,
  });
  final String schema;
  final String name;
  final String kind;
  final int estimatedRows;
}

class ColumnInfo {
  const ColumnInfo({
    required this.name,
    required this.type,
    required this.typeName,
    required this.nullable,
    required this.defaultExpr,
    required this.isGenerated,
    required this.isIdentity,
    this.enumValues,
    this.accessLevel = AccessLevel.full,
    this.defaultHidden = false,
  });
  final String name;
  final PgType type;
  final String typeName;
  final bool nullable;
  final String? defaultExpr;
  final bool isGenerated;
  final bool isIdentity;
  final List<String>? enumValues;

  /// Access level resolved for the viewer (schema metadata access control).
  /// `full` when no access control applies. Columns at `none` never reach
  /// a [ColumnInfo]: the catalog drops them.
  final AccessLevel accessLevel;

  /// Collapsed when a table opens (access-control `default_hidden`).
  final bool defaultHidden;

  bool get isMasked => accessLevel == AccessLevel.masked;

  ColumnInfo withAccess(AccessLevel level, {required bool defaultHidden}) =>
      ColumnInfo(
        name: name,
        type: type,
        typeName: typeName,
        nullable: nullable,
        defaultExpr: defaultExpr,
        isGenerated: isGenerated,
        isIdentity: isIdentity,
        enumValues: enumValues,
        accessLevel: level,
        defaultHidden: defaultHidden,
      );
}

class ForeignKey {
  const ForeignKey({
    required this.constraintName,
    required this.fromSchema,
    required this.fromTable,
    required this.fromColumn,
    required this.toSchema,
    required this.toTable,
    required this.toColumn,
    this.isVirtual = false,
  });
  final String constraintName;
  final String fromSchema;
  final String fromTable;
  final String fromColumn;
  final String toSchema;
  final String toTable;
  final String toColumn;

  /// True for a relationship declared in schema metadata (a `link` row)
  /// rather than by a real constraint. Drawn dashed in the Schema view.
  final bool isVirtual;

  String get fromKey => '$fromSchema.$fromTable';
  String get toKey => '$toSchema.$toTable';

  /// Stable identifier for a logical constraint (composite FKs share this).
  String get constraintKey => '$fromSchema.$fromTable.$constraintName';
}

class TableSchema {
  const TableSchema({
    required this.columns,
    required this.pkColumns,
    required this.indexedColumns,
  });
  final List<ColumnInfo> columns;
  final List<String> pkColumns;
  final Set<String> indexedColumns;
}

// SQLite has no schemas in the Postgres sense; everything is in 'main'.
// Catalog methods that take a `schema` accept 'main' and route through
// pragma_* table-valued functions and sqlite_master.
const _kSqliteMainSchema = 'main';

/// Reads the database catalog. The default constructor filters every
/// answer through the connection's access policy (schema metadata): tables
/// and columns at `none` disappear, masked columns are flagged, virtual
/// relationships from `link` rows are added. That makes this class the one
/// choke point for access control — the sidebar, Schema view, Navigator,
/// Linked view, DBML export and AI context all read the catalog.
///
/// [SchemaCatalog.unfiltered] is for DML and internals that must see the
/// real shape (e.g. primary keys of a table whose PK is hidden).
class SchemaCatalog {
  SchemaCatalog(this.conn) : _applyPolicy = true;
  SchemaCatalog.unfiltered(this.conn) : _applyPolicy = false;
  final DbExecutor conn;
  final bool _applyPolicy;

  bool get _isSqlite => conn.kind == kSqliteKind;

  AccessPolicy get _policy => _applyPolicy
      ? MetadataCache.instance.policyForExecutor(conn)
      : AccessPolicy.unrestricted;

  MetaSnapshot? get _snapshot =>
      _applyPolicy ? MetadataCache.instance.snapshotForExecutor(conn) : null;

  Future<List<SchemaInfo>> listSchemas() async {
    final all = await _listSchemasRaw();
    final policy = _policy;
    final snapshot = _snapshot;
    if (!policy.active || snapshot == null || snapshot.isSqlite) return all;
    if (policy.can(Capability.manage)) return all;
    return [
      for (final schema in all)
        if (!MetaTableNames.isDedicatedMetaSchema(
          schema.name,
          snapshot.settings,
        ))
          schema,
    ];
  }

  Future<List<SchemaInfo>> _listSchemasRaw() async {
    if (_isSqlite) {
      // Only the default database is exposed. ATTACH DATABASE is a real
      // SQLite feature but out of scope for v1 — users with attached
      // DBs can still query them via fully-qualified SQL in a Query tab.
      return const [SchemaInfo(_kSqliteMainSchema, isSystem: false)];
    }
    final result = await conn.execute(
      'SELECT schema_name FROM information_schema.schemata ORDER BY schema_name',
    );
    final out = <SchemaInfo>[];
    for (final row in result.rows) {
      final name = row[0]! as String;
      final isSystem = name.startsWith('pg_') || name == 'information_schema';
      out.add(SchemaInfo(name, isSystem: isSystem));
    }
    out.sort((a, b) {
      if (a.isSystem != b.isSystem) return a.isSystem ? 1 : -1;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  Future<List<TableInfo>> listTables(String schema) async {
    final all = await _listTablesRaw(schema);
    final policy = _policy;
    if (!policy.active) return all;
    return [
      for (final table in all)
        if (!policy.forTable(table.schema, table.name).isNone) table,
    ];
  }

  Future<List<TableInfo>> _listTablesRaw(String schema) async {
    if (_isSqlite) return _sqliteListTables(schema);
    final result = await conn.execute(
      '''
 SELECT
 t.table_name,
 t.table_type,
 COALESCE(c.reltuples, -1)::bigint AS estimated_rows
 FROM information_schema.tables t
 LEFT JOIN pg_class c
 ON c.relname = t.table_name
 AND c.relnamespace = (
 SELECT oid FROM pg_namespace WHERE nspname = t.table_schema
 )
 WHERE t.table_schema = @schema
 ORDER BY t.table_name
 ''',
      named: {'schema': schema},
    );
    return [
      for (final row in result.rows)
        TableInfo(
          schema: schema,
          name: row[0]! as String,
          kind: row[1]! as String,
          estimatedRows: toInt(row[2]) ?? -1,
        ),
    ];
  }

  Future<List<TableInfo>> _sqliteListTables(String schema) async {
    // Only 'main' is exposed. sqlite_master.type is 'table' or 'view';
    // skip internal sqlite_* tables. No row-count estimate exists, so we
    // surface -1 (callers treat -1 as "unknown" and skip the badge).
    final result = await conn.execute(
      '''
 SELECT name,
 CASE type WHEN 'table' THEN 'BASE TABLE' ELSE 'VIEW' END AS kind
 FROM sqlite_master
 WHERE type IN ('table', 'view')
 AND name NOT LIKE 'sqlite_%'
 ORDER BY name
 ''',
    );
    return [
      for (final row in result.rows)
        TableInfo(
          schema: schema,
          name: row[0]! as String,
          kind: row[1]! as String,
          estimatedRows: -1,
        ),
    ];
  }

  Future<List<ColumnInfo>> listColumns(String schema, String table) async {
    final all = await _listColumnsRaw(schema, table);
    final policy = _policy;
    if (!policy.active) return all;
    if (policy.forTable(schema, table).isNone) return const [];
    Set<String>? primaryKeyNames;
    final out = <ColumnInfo>[];
    for (final column in all) {
      var decision = policy.forColumn(schema, table, column.name);
      if (decision.isNone) {
        primaryKeyNames ??= (await primaryKey(schema, table)).toSet();
        if (!primaryKeyNames.contains(column.name)) continue;
        decision = policy.forColumn(
          schema,
          table,
          column.name,
          isPrimaryKey: true,
        );
      }
      out.add(
        column.withAccess(
          decision.level,
          defaultHidden: decision.defaultHidden,
        ),
      );
    }
    return out;
  }

  Future<List<ColumnInfo>> _listColumnsRaw(String schema, String table) async {
    if (_isSqlite) return _sqliteListColumns(schema, table);
    final result = await conn.execute(
      '''
 SELECT
 c.column_name::text,
 c.data_type::text,
 c.udt_name::text,
 (c.is_nullable = 'YES') AS nullable,
 c.column_default::text,
 (a.attgenerated <> '') AS is_generated,
 (a.attidentity <> '') AS is_identity,
 t.typtype::text AS udt_kind,
 c.udt_schema::text
 FROM information_schema.columns c
 JOIN pg_attribute a
 ON a.attrelid = (quote_ident(c.table_schema) || '.' || quote_ident(c.table_name))::regclass
 AND a.attname = c.column_name
 LEFT JOIN pg_type t
 ON t.typname = c.udt_name
 AND t.typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = c.udt_schema)
 WHERE c.table_schema = @schema
 AND c.table_name = @table
 ORDER BY c.ordinal_position
 ''',
      named: {'schema': schema, 'table': table},
    );
    final enumLookups = <(String udtSchema, String udtName), int>{};
    final raw = <_ColumnRaw>[];
    for (final row in result.rows) {
      final udtName = row[2]! as String;
      final udtSchema = row[8] as String?;
      final udtKind = row[7] as String?;
      raw.add(
        _ColumnRaw(
          name: row[0]! as String,
          udtName: udtName,
          nullable: toBool(row[3]),
          defaultExpr: row[4] as String?,
          isGenerated: toBool(row[5]),
          isIdentity: toBool(row[6]),
          udtSchema: udtSchema,
          isEnum: udtKind == 'e',
        ),
      );
      if (udtKind == 'e' && udtSchema != null) {
        enumLookups[(udtSchema, udtName)] = enumLookups.length;
      }
    }
    final enumValues = await _loadEnumValues(enumLookups.keys.toList());
    return [
      for (final rawColumn in raw)
        ColumnInfo(
          name: rawColumn.name,
          type: pgTypeFromUdt(rawColumn.udtName),
          typeName: rawColumn.udtName,
          nullable: rawColumn.nullable,
          defaultExpr: rawColumn.defaultExpr,
          isGenerated: rawColumn.isGenerated,
          isIdentity: rawColumn.isIdentity,
          enumValues: rawColumn.isEnum && rawColumn.udtSchema != null
              ? enumValues[(rawColumn.udtSchema!, rawColumn.udtName)]
              : null,
        ),
    ];
  }

  Future<List<ColumnInfo>> _sqliteListColumns(
    String schema,
    String table,
  ) async {
    // PRAGMA table_xinfo returns the same columns as table_info plus
    // `hidden` (used for virtual tables / generated columns). The
    // `pragma_table_xinfo(?)` table-valued form is parameterisable.
    // Columns: cid, name, type, notnull, dflt_value, pk, hidden.
    final result = await conn.execute(
      'SELECT name, type, "notnull", dflt_value, pk, hidden '
      'FROM pragma_table_xinfo(?) ORDER BY cid',
      positional: [table],
    );
    return [
      for (final row in result.rows)
        ColumnInfo(
          name: row[0]! as String,
          type: pgTypeFromSqlite((row[1] as String?) ?? ''),
          typeName: (row[1] as String?) ?? '',
          nullable: toInt(row[2]) == 0,
          defaultExpr: row[3] as String?,
          // hidden == 2 means a STORED generated column, 3 means VIRTUAL.
          isGenerated: (toInt(row[5]) ?? 0) >= 2,
          // SQLite's INTEGER PRIMARY KEY is the rowid alias (identity-ish);
          // we surface that as identity for callers that gate INSERT-time
          // value entry.
          isIdentity: false,
        ),
    ];
  }

  Future<Map<(String, String), List<String>>> _loadEnumValues(
    List<(String, String)> keys,
  ) async {
    if (keys.isEmpty) return const {};
    final params = <Object?>[];
    final pairs = <String>[];
    for (final k in keys) {
      params.add(k.$1);
      final s = '\$${params.length}';
      params.add(k.$2);
      final n = '\$${params.length}';
      pairs.add('(n.nspname = $s AND t.typname = $n)');
    }
    final sql =
        '''
 SELECT n.nspname, t.typname, e.enumlabel
 FROM pg_enum e
 JOIN pg_type t ON t.oid = e.enumtypid
 JOIN pg_namespace n ON n.oid = t.typnamespace
 WHERE ${pairs.join(' OR ')}
 ORDER BY e.enumsortorder
 ''';
    final result = await conn.execute(sql, positional: params);
    final out = <(String, String), List<String>>{};
    for (final row in result.rows) {
      final k = (row[0]! as String, row[1]! as String);
      (out[k] ??= <String>[]).add(row[2]! as String);
    }
    return out;
  }

  Future<List<String>> primaryKey(String schema, String table) async {
    if (_isSqlite) {
      // pk = 0 means not part of the PK; > 0 is the column's position in
      // the PK (1-based). Sort by pk to get the composite-PK order.
      final result = await conn.execute(
        'SELECT name FROM pragma_table_info(?) '
        'WHERE pk > 0 ORDER BY pk',
        positional: [table],
      );
      return [for (final row in result.rows) row[0]! as String];
    }
    final result = await conn.execute(
      '''
 SELECT a.attname
 FROM pg_index i
 JOIN pg_attribute a
 ON a.attrelid = i.indrelid
 AND a.attnum = ANY(i.indkey)
 WHERE i.indrelid = (quote_ident(@schema) || '.' || quote_ident(@table))::regclass
 AND i.indisprimary
 ORDER BY array_position(i.indkey::int[], a.attnum::int)
 ''',
      named: {'schema': schema, 'table': table},
    );
    return [for (final row in result.rows) row[0]! as String];
  }

  Future<Set<String>> indexedColumns(String schema, String table) async {
    if (_isSqlite) {
      // pragma_index_list lists every index on the table; we then expand
      // each one via pragma_index_info to collect the indexed column
      // names. PK and UNIQUE indexes are included; partial-index
      // predicates are ignored (no SQLite pragma surfaces them as a
      // filter we can introspect).
      final indexes = await conn.execute(
        'SELECT name FROM pragma_index_list(?)',
        positional: [table],
      );
      final columns = <String>{};
      for (final indexRow in indexes.rows) {
        final idxName = indexRow[0]! as String;
        final info = await conn.execute(
          'SELECT name FROM pragma_index_info(?)',
          positional: [idxName],
        );
        for (final ir in info.rows) {
          final name = ir[0];
          if (name is String) columns.add(name);
        }
      }
      return columns;
    }
    final result = await conn.execute(
      '''
 SELECT DISTINCT a.attname
 FROM pg_index i
 JOIN pg_attribute a
 ON a.attrelid = i.indrelid
 AND a.attnum = ANY(i.indkey)
 WHERE i.indrelid = (quote_ident(@schema) || '.' || quote_ident(@table))::regclass
 ''',
      named: {'schema': schema, 'table': table},
    );
    return {for (final row in result.rows) row[0]! as String};
  }

  Future<List<ForeignKey>> listForeignKeys() async {
    final real = await _listForeignKeysRaw();
    final snapshot = _snapshot;
    final virtual = snapshot == null
        ? const <ForeignKey>[]
        : await _virtualForeignKeys(snapshot);
    final all = [...real, ...virtual];
    final policy = _policy;
    if (!policy.active) return all;
    bool visible(String schema, String table, String column) =>
        !policy.forColumn(schema, table, column).isNone;
    return [
      for (final foreignKey in all)
        if (visible(
              foreignKey.fromSchema,
              foreignKey.fromTable,
              foreignKey.fromColumn,
            ) &&
            visible(
              foreignKey.toSchema,
              foreignKey.toTable,
              foreignKey.toColumn,
            ))
          foreignKey,
    ];
  }

  /// `link` rows with a plain `to` become virtual FKs. Glob targets
  /// (`*.*.owner_id`) are expanded against the real columns; polymorphic
  /// and URL links depend on row values, so the inspector resolves those
  /// per row instead.
  Future<List<ForeignKey>> _virtualForeignKeys(MetaSnapshot snapshot) async {
    final links = [
      for (final link in snapshot.index.links)
        if (link.to?.exactColumn != null && link.target.isColumnLevel) link,
    ];
    if (links.isEmpty) return const [];
    final out = <ForeignKey>[];
    final needsExpansion = links.any(
      (link) => link.target.exactColumn == null,
    );
    var allColumns = const <(String, String, String)>[];
    if (needsExpansion) allColumns = await _allColumnTriples();
    for (final link in links) {
      final to = link.to!.exactColumn!;
      final exact = link.target.exactColumn;
      final sources = exact != null
          ? [(exact.schema, exact.table, exact.column)]
          : [
              for (final columnTriple in allColumns)
                if (link.target.matchesColumn(
                  columnTriple.$1,
                  columnTriple.$2,
                  columnTriple.$3,
                ))
                  columnTriple,
            ];
      for (final source in sources) {
        out.add(
          ForeignKey(
            constraintName: 'virtual:${link.id}',
            fromSchema: source.$1,
            fromTable: source.$2,
            fromColumn: source.$3,
            toSchema: to.schema,
            toTable: to.table,
            toColumn: to.column,
            isVirtual: true,
          ),
        );
      }
    }
    return out;
  }

  Future<List<(String, String, String)>> _allColumnTriples() async {
    if (_isSqlite) {
      final out = <(String, String, String)>[];
      for (final table in await _sqliteListTables(_kSqliteMainSchema)) {
        final columnRows = await conn.execute(
          'SELECT name FROM pragma_table_info(?)',
          positional: [table.name],
        );
        for (final row in columnRows.rows) {
          out.add((_kSqliteMainSchema, table.name, row[0]! as String));
        }
      }
      return out;
    }
    final result = await conn.execute('''
 SELECT table_schema::text, table_name::text, column_name::text
 FROM information_schema.columns
 WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
 ''');
    return [
      for (final row in result.rows)
        (row[0]! as String, row[1]! as String, row[2]! as String),
    ];
  }

  Future<List<ForeignKey>> _listForeignKeysRaw() async {
    if (_isSqlite) return _sqliteListForeignKeys();
    final result = await conn.execute(
      '''
 SELECT
 con.conname,
 src_ns.nspname,
 src_cls.relname,
 src_att.attname,
 tgt_ns.nspname,
 tgt_cls.relname,
 tgt_att.attname,
 sk.ord
 FROM pg_constraint con
 JOIN pg_class src_cls ON src_cls.oid = con.conrelid
 JOIN pg_namespace src_ns ON src_ns.oid = src_cls.relnamespace
 JOIN pg_class tgt_cls ON tgt_cls.oid = con.confrelid
 JOIN pg_namespace tgt_ns ON tgt_ns.oid = tgt_cls.relnamespace
 JOIN unnest(con.conkey) WITH ORDINALITY AS sk(attnum, ord) ON true
 JOIN unnest(con.confkey) WITH ORDINALITY AS tk(attnum, ord) USING (ord)
 JOIN pg_attribute src_att
 ON src_att.attrelid = con.conrelid AND src_att.attnum = sk.attnum
 JOIN pg_attribute tgt_att
 ON tgt_att.attrelid = con.confrelid AND tgt_att.attnum = tk.attnum
 WHERE con.contype = 'f'
 AND src_ns.nspname NOT IN ('pg_catalog', 'information_schema')
 ORDER BY src_ns.nspname, src_cls.relname, con.conname, sk.ord
 ''',
    );
    return [
      for (final row in result.rows)
        ForeignKey(
          constraintName: row[0]! as String,
          fromSchema: row[1]! as String,
          fromTable: row[2]! as String,
          fromColumn: row[3]! as String,
          toSchema: row[4]! as String,
          toTable: row[5]! as String,
          toColumn: row[6]! as String,
        ),
    ];
  }

  Future<List<ForeignKey>> _sqliteListForeignKeys() async {
    // SQLite exposes FKs per-table via pragma_foreign_key_list. We list
    // every user table and union the per-table results. Composite FKs
    // share an `id`; the synthesized constraintName uses that id so the
    // gutter math (constraintKey) groups composite edges correctly.
    final tables = await _sqliteListTables(_kSqliteMainSchema);
    final out = <ForeignKey>[];
    for (final table in tables) {
      if (table.kind != 'BASE TABLE') continue;
      final result = await conn.execute(
        'SELECT id, seq, "table", "from", "to" '
        'FROM pragma_foreign_key_list(?) ORDER BY id, seq',
        positional: [table.name],
      );
      for (final row in result.rows) {
        final id = toInt(row[0]) ?? 0;
        final seq = toInt(row[1]) ?? 0;
        final refTable = row[2]! as String;
        final fromColumn = row[3]! as String;
        // `to` is null when the FK targets the PK implicitly. In that
        // case we resolve via the target table's PK column at position
        // [seq]. Falling back to empty produces a still-readable edge.
        var toColumn = row[4] as String?;
        if (toColumn == null || toColumn.isEmpty) {
          final primaryKeyColumns = await primaryKey(
            _kSqliteMainSchema,
            refTable,
          );
          toColumn = (seq >= 0 && seq < primaryKeyColumns.length)
              ? primaryKeyColumns[seq]
              : '';
        }
        out.add(
          ForeignKey(
            constraintName: 'fk_${table.name}_$id',
            fromSchema: _kSqliteMainSchema,
            fromTable: table.name,
            fromColumn: fromColumn,
            toSchema: _kSqliteMainSchema,
            toTable: refTable,
            toColumn: toColumn,
          ),
        );
      }
    }
    return out;
  }

  /// Return the SQL definition of a CHECK constraint by name, e.g.
  /// `"CHECK ((quantity > 0))"`. Returns null when the name isn't a
  /// CHECK or isn't found. Used to enrich the toast that follows a
  /// 23514 (check_violation) error so users see *what* rule fired,
  /// not just its opaque name.
  Future<String?> lookupCheckDefinition(String constraintName) async {
    if (_isSqlite) return null;
    final result = await conn.execute(
      '''
 SELECT pg_get_constraintdef(con.oid, true) AS def
 FROM pg_constraint con
 WHERE con.contype = 'c' AND con.conname = @name
 LIMIT 1
 ''',
      named: {'name': constraintName},
    );
    if (result.isEmpty) return null;
    final raw = result.first[0];
    return raw is String ? raw : null;
  }

  Future<int> exactCount(String schema, String table) async {
    final qualified =
        '"${schema.replaceAll('"', '""')}"."${table.replaceAll('"', '""')}"';
    final result = await conn.execute('SELECT count(*) FROM $qualified');
    return toInt(result.rows.first[0]) ?? 0;
  }

  /// Loads a single row by its primary-key tuple. Returns null if the row
  /// no longer exists. The returned map is keyed by the result-set column
  /// names so the caller can pair values to [listColumns] metadata.
  Future<Map<String, Object?>?> loadRowByPk({
    required String schema,
    required String table,
    required List<String> pkColumns,
    required List<Object?> pkValues,
  }) async {
    if (pkColumns.isEmpty) {
      throw ArgumentError('loadRowByPk requires at least one PK column.');
    }
    if (pkColumns.length != pkValues.length) {
      throw ArgumentError('pkColumns and pkValues length mismatch.');
    }
    final qualified = quoteQualified(schema, table);
    final params = <Object?>[];
    final wherePlaceholders = <String>[];
    for (var i = 0; i < pkColumns.length; i++) {
      params.add(pkValues[i]);
      wherePlaceholders.add('${quoteIdent(pkColumns[i])} = \$${params.length}');
    }
    // With access control, select only what the viewer may see: `none`
    // columns are left out entirely and masked ones come back as NULL.
    var selectList = '*';
    final masked = <String>{};
    if (_policy.active) {
      final columns = await listColumns(schema, table);
      if (columns.isEmpty) return null;
      selectList = [
        for (final column in columns)
          if (column.isMasked && !pkColumns.contains(column.name))
            'NULL AS ${quoteIdent(column.name)}'
          else
            quoteIdent(column.name),
      ].join(', ');
      masked.addAll([
        for (final column in columns)
          if (column.isMasked) column.name,
      ]);
    }
    final sql =
        'SELECT $selectList FROM $qualified '
        'WHERE ${wherePlaceholders.join(' AND ')} LIMIT 1';
    final result = await conn.execute(sql, positional: params);
    if (result.isEmpty) return null;
    final row = result.first;
    final map = <String, Object?>{};
    for (var i = 0; i < result.columns.length; i++) {
      final name = result.columns[i].name;
      map[name] = masked.contains(name) ? MaskedValue.instance : row[i];
    }
    return map;
  }
}

class _ColumnRaw {
  _ColumnRaw({
    required this.name,
    required this.udtName,
    required this.nullable,
    required this.defaultExpr,
    required this.isGenerated,
    required this.isIdentity,
    required this.udtSchema,
    required this.isEnum,
  });
  final String name;
  final String udtName;
  final bool nullable;
  final String? defaultExpr;
  final bool isGenerated;
  final bool isIdentity;
  final String? udtSchema;
  final bool isEnum;
}
