import '../db/executor.dart';
import '../db/sqlite_kind.dart';
import '../util/db_coerce.dart';
import '../util/sql_quote.dart';
import 'pg_type.dart';

class SchemaInfo {
  final String name;
  final bool isSystem;
  const SchemaInfo(this.name, this.isSystem);
}

class TableInfo {
  final String schema;
  final String name;
  final String kind;
  final int estimatedRows;
  const TableInfo({
    required this.schema,
    required this.name,
    required this.kind,
    required this.estimatedRows,
  });
}

class ColumnInfo {
  final String name;
  final PgType type;
  final String typeName;
  final bool nullable;
  final String? defaultExpr;
  final bool isGenerated;
  final bool isIdentity;
  final List<String>? enumValues;

  const ColumnInfo({
    required this.name,
    required this.type,
    required this.typeName,
    required this.nullable,
    required this.defaultExpr,
    required this.isGenerated,
    required this.isIdentity,
    this.enumValues,
  });
}

class ForeignKey {
  final String constraintName;
  final String fromSchema;
  final String fromTable;
  final String fromColumn;
  final String toSchema;
  final String toTable;
  final String toColumn;
  const ForeignKey({
    required this.constraintName,
    required this.fromSchema,
    required this.fromTable,
    required this.fromColumn,
    required this.toSchema,
    required this.toTable,
    required this.toColumn,
  });

  String get fromKey => '$fromSchema.$fromTable';
  String get toKey => '$toSchema.$toTable';

  /// Stable identifier for a logical constraint (composite FKs share this).
  String get constraintKey => '$fromSchema.$fromTable.$constraintName';
}

class TableSchema {
  final List<ColumnInfo> columns;
  final List<String> pkColumns;
  final Set<String> indexedColumns;

  const TableSchema({
    required this.columns,
    required this.pkColumns,
    required this.indexedColumns,
  });
}

// SQLite has no schemas in the Postgres sense; everything is in 'main'.
// Catalog methods that take a `schema` accept 'main' and route through
// pragma_* table-valued functions and sqlite_master.
const String _kSqliteMainSchema = 'main';

class SchemaCatalog {
  final DbExecutor conn;
  SchemaCatalog(this.conn);

  bool get _isSqlite => conn.kind == kSqliteKind;

  Future<List<SchemaInfo>> listSchemas() async {
    if (_isSqlite) {
      // Only the default database is exposed. ATTACH DATABASE is a real
      // SQLite feature but out of scope for v1 — users with attached
      // DBs can still query them via fully-qualified SQL in a Query tab.
      return const [SchemaInfo(_kSqliteMainSchema, false)];
    }
    final result = await conn.execute(
      'SELECT schema_name FROM information_schema.schemata ORDER BY schema_name',
    );
    final out = <SchemaInfo>[];
    for (final row in result.rows) {
      final name = row[0] as String;
      final isSystem = name.startsWith('pg_') || name == 'information_schema';
      out.add(SchemaInfo(name, isSystem));
    }
    out.sort((a, b) {
      if (a.isSystem != b.isSystem) return a.isSystem ? 1 : -1;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  Future<List<TableInfo>> listTables(String schema) async {
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
          name: row[0] as String,
          kind: row[1] as String,
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
          name: row[0] as String,
          kind: row[1] as String,
          estimatedRows: -1,
        ),
    ];
  }

  Future<List<ColumnInfo>> listColumns(String schema, String table) async {
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
      final udtName = row[2] as String;
      final udtSchema = row[8] as String?;
      final udtKind = row[7] as String?;
      raw.add(
        _ColumnRaw(
          name: row[0] as String,
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
      for (final r in raw)
        ColumnInfo(
          name: r.name,
          type: pgTypeFromUdt(r.udtName),
          typeName: r.udtName,
          nullable: r.nullable,
          defaultExpr: r.defaultExpr,
          isGenerated: r.isGenerated,
          isIdentity: r.isIdentity,
          enumValues: r.isEnum && r.udtSchema != null
              ? enumValues[(r.udtSchema!, r.udtName)]
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
          name: row[0] as String,
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
      final k = (row[0] as String, row[1] as String);
      (out[k] ??= <String>[]).add(row[2] as String);
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
      return [for (final row in result.rows) row[0] as String];
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
    return [for (final row in result.rows) row[0] as String];
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
      final cols = <String>{};
      for (final r in indexes.rows) {
        final idxName = r[0] as String;
        final info = await conn.execute(
          'SELECT name FROM pragma_index_info(?)',
          positional: [idxName],
        );
        for (final ir in info.rows) {
          final name = ir[0];
          if (name is String) cols.add(name);
        }
      }
      return cols;
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
    return {for (final row in result.rows) row[0] as String};
  }

  Future<List<ForeignKey>> listForeignKeys() async {
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
          constraintName: row[0] as String,
          fromSchema: row[1] as String,
          fromTable: row[2] as String,
          fromColumn: row[3] as String,
          toSchema: row[4] as String,
          toTable: row[5] as String,
          toColumn: row[6] as String,
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
    for (final t in tables) {
      if (t.kind != 'BASE TABLE') continue;
      final res = await conn.execute(
        'SELECT id, seq, "table", "from", "to" '
        'FROM pragma_foreign_key_list(?) ORDER BY id, seq',
        positional: [t.name],
      );
      for (final r in res.rows) {
        final id = toInt(r[0]) ?? 0;
        final seq = toInt(r[1]) ?? 0;
        final refTable = r[2] as String;
        final fromCol = r[3] as String;
        // `to` is null when the FK targets the PK implicitly. In that
        // case we resolve via the target table's PK column at position
        // [seq]. Falling back to empty produces a still-readable edge.
        var toCol = (r[4] as String?);
        if (toCol == null || toCol.isEmpty) {
          final pk = await primaryKey(_kSqliteMainSchema, refTable);
          toCol = (seq >= 0 && seq < pk.length) ? pk[seq] : '';
        }
        out.add(
          ForeignKey(
            constraintName: 'fk_${t.name}_$id',
            fromSchema: _kSqliteMainSchema,
            fromTable: t.name,
            fromColumn: fromCol,
            toSchema: _kSqliteMainSchema,
            toTable: refTable,
            toColumn: toCol,
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
    final sql =
        'SELECT * FROM $qualified WHERE ${wherePlaceholders.join(' AND ')} LIMIT 1';
    final result = await conn.execute(sql, positional: params);
    if (result.isEmpty) return null;
    final row = result.first;
    final map = <String, Object?>{};
    for (var i = 0; i < result.columns.length; i++) {
      map[result.columns[i].name] = row[i];
    }
    return map;
  }
}

class _ColumnRaw {
  final String name;
  final String udtName;
  final bool nullable;
  final String? defaultExpr;
  final bool isGenerated;
  final bool isIdentity;
  final String? udtSchema;
  final bool isEnum;

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
}
