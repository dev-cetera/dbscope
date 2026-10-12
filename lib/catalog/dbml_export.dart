import '../db/executor.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_index.dart';
import 'schema_catalog.dart';

class DbmlExportProgress {
  const DbmlExportProgress({
    required this.completed,
    required this.total,
    required this.currentTable,
  });
  final int completed;
  final int total;
  final String currentTable;
}

typedef DbmlProgressCallback = void Function(DbmlExportProgress);

class DbmlEnum {
  const DbmlEnum(this.schema, this.name, this.values);
  final String schema;
  final String name;
  final List<String> values;
}

class DbmlExporter {
  DbmlExporter(this.conn, {this.databaseName = 'dbscope'});
  final DbExecutor conn;
  final String databaseName;

  /// Schema metadata for this connection, when loaded: descriptions become
  /// DBML notes, which is how the AI features learn what columns mean.
  MetaIndex? get _meta =>
      MetadataCache.instance.snapshotForExecutor(conn)?.index;

  Future<String> generate({DbmlProgressCallback? onProgress}) async {
    // The filtered catalog: tables and columns at access level `none` never
    // reach the DBML (and so never reach an AI prompt).
    final catalog = SchemaCatalog(conn);

    final schemas = (await catalog.listSchemas())
        .where((s) => !s.isSystem)
        .toList();

    final allTables = <TableInfo>[];
    for (final s in schemas) {
      final tables = await catalog.listTables(s.name);
      allTables.addAll(tables.where((t) => t.kind == 'BASE TABLE'));
    }

    final enums = await _loadEnums(schemas.map((s) => s.name).toList());

    final fks = await catalog.listForeignKeys();

    final buf = StringBuffer();
    buf.writeln('Project $databaseName {');
    buf.writeln(" database_type: 'PostgreSQL'");
    buf.writeln('}');
    buf.writeln();

    for (final e in enums) {
      _writeEnum(buf, e);
      buf.writeln();
    }

    for (var i = 0; i < allTables.length; i++) {
      final t = allTables[i];
      onProgress?.call(
        DbmlExportProgress(
          completed: i,
          total: allTables.length,
          currentTable: '${t.schema}.${t.name}',
        ),
      );
      final cols = await catalog.listColumns(t.schema, t.name);
      final pk = await catalog.primaryKey(t.schema, t.name);
      _writeTable(buf, t, cols, pk);
      buf.writeln();
    }
    onProgress?.call(
      DbmlExportProgress(
        completed: allTables.length,
        total: allTables.length,
        currentTable: '',
      ),
    );

    _writeForeignKeys(buf, fks);

    return buf.toString();
  }

  Future<List<DbmlEnum>> _loadEnums(List<String> schemas) async {
    if (schemas.isEmpty) return const [];
    final params = <Object?>[];
    final placeholders = <String>[];
    for (final s in schemas) {
      params.add(s);
      placeholders.add('\$${params.length}');
    }
    final sql =
        '''
 SELECT n.nspname, t.typname, e.enumlabel
 FROM pg_type t
 JOIN pg_enum e ON e.enumtypid = t.oid
 JOIN pg_namespace n ON n.oid = t.typnamespace
 WHERE n.nspname IN (${placeholders.join(', ')})
 ORDER BY n.nspname, t.typname, e.enumsortorder
 ''';
    final result = await conn.execute(sql, positional: params);
    final grouped = <(String, String), List<String>>{};
    for (final row in result.rows) {
      final key = (row[0]! as String, row[1]! as String);
      (grouped[key] ??= <String>[]).add(row[2]! as String);
    }
    return [
      for (final entry in grouped.entries)
        DbmlEnum(entry.key.$1, entry.key.$2, entry.value),
    ];
  }

  void _writeEnum(StringBuffer buf, DbmlEnum e) {
    buf.writeln('Enum ${_qualifiedRef(e.schema, e.name)} {');
    for (final v in e.values) {
      buf.writeln(' ${_quoteIfNeeded(v)}');
    }
    buf.writeln('}');
  }

  void _writeTable(
    StringBuffer buf,
    TableInfo t,
    List<ColumnInfo> cols,
    List<String> pk,
  ) {
    final pkSet = pk.toSet();
    final singlePk = pk.length == 1 ? pk.first : null;
    buf.writeln('Table ${_qualifiedRef(t.schema, t.name)} {');
    for (final c in cols) {
      final attrs = <String>[];
      if (singlePk == c.name) attrs.add('pk');
      if (c.isIdentity) attrs.add('increment');
      if (!c.nullable && !pkSet.contains(c.name)) attrs.add('not null');
      final def = c.defaultExpr;
      if (def != null && def.toUpperCase() != 'NULL' && !c.isGenerated) {
        attrs.add('default: `${_escapeBacktick(def)}`');
      }
      final note = _columnNote(t, c);
      if (note != null) attrs.add("note: '${_escapeNote(note)}'");
      final attrStr = attrs.isEmpty ? '' : ' [${attrs.join(', ')}]';
      buf.writeln(' ${_columnName(c.name)} ${_dbmlType(c)}$attrStr');
    }
    final tableNote = _meta?.describeTable(t.schema, t.name).description;
    if (tableNote != null) buf.writeln(" Note: '${_escapeNote(tableNote)}'");
    if (pk.length > 1) {
      buf.writeln(' indexes {');
      final cols = pk.map(_columnName).join(', ');
      buf.writeln(' ($cols) [pk]');
      buf.writeln(' }');
    }
    buf.writeln('}');
  }

  void _writeForeignKeys(StringBuffer buf, List<ForeignKey> fks) {
    final byConstraint = <String, List<ForeignKey>>{};
    for (final fk in fks) {
      (byConstraint[fk.constraintKey] ??= <ForeignKey>[]).add(fk);
    }
    for (final group in byConstraint.values) {
      final first = group.first;
      final from = group.length == 1
          ? '${_qualifiedRef(first.fromSchema, first.fromTable)}.${_columnName(first.fromColumn)}'
          : '${_qualifiedRef(first.fromSchema, first.fromTable)}.'
                '(${group.map((g) => _columnName(g.fromColumn)).join(', ')})';
      final to = group.length == 1
          ? '${_qualifiedRef(first.toSchema, first.toTable)}.${_columnName(first.toColumn)}'
          : '${_qualifiedRef(first.toSchema, first.toTable)}.'
                '(${group.map((g) => _columnName(g.toColumn)).join(', ')})';
      buf.writeln(
        'Ref: $from > $to${first.isVirtual ? ' // virtual (metadata link)' : ''}',
      );
    }
  }

  String _dbmlType(ColumnInfo c) {
    final name = c.typeName;
    if (name.startsWith('_')) {
      return '${name.substring(1)}[]';
    }
    return name;
  }

  String _qualifiedRef(String schema, String name) => '"$schema"."$name"';

  String _columnName(String name) {
    if (_isSimpleIdent(name)) return name;
    return '"$name"';
  }

  bool _isSimpleIdent(String s) {
    if (s.isEmpty) return false;
    final r = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    return r.hasMatch(s);
  }

  String _quoteIfNeeded(String s) {
    if (_isSimpleIdent(s)) return s;
    return '"${s.replaceAll('"', r'\"')}"';
  }

  String _escapeBacktick(String s) => s.replaceAll('`', r'\`');

  /// Description + enum meanings for a column, plus a marker when the
  /// viewer only sees it masked.
  String? _columnNote(TableInfo t, ColumnInfo c) {
    final describe = _meta?.describeColumn(t.schema, t.name, c.name);
    final parts = <String>[
      ?describe?.description,
      if (describe?.unit != null) 'unit: ${describe!.unit}',
      if (describe != null && describe.values.isNotEmpty)
        'values: ${describe.values.entries.map((e) => '${e.key} = ${e.value}').join('; ')}',
      if (describe?.deprecated != null) 'deprecated: ${describe!.deprecated}',
      if (c.isMasked) 'masked for this user',
    ];
    return parts.isEmpty ? null : parts.join(' | ');
  }

  String _escapeNote(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', ' ');
}
