import '../db/executor.dart';
import 'schema_catalog.dart';

class DbmlExportProgress {
  final int completed;
  final int total;
  final String currentTable;
  const DbmlExportProgress({
    required this.completed,
    required this.total,
    required this.currentTable,
  });
}

typedef DbmlProgressCallback = void Function(DbmlExportProgress);

class DbmlEnum {
  final String schema;
  final String name;
  final List<String> values;
  const DbmlEnum(this.schema, this.name, this.values);
}

class DbmlExporter {
  final DbExecutor conn;
  final String databaseName;

  DbmlExporter(this.conn, {this.databaseName = 'dbscope'});

  Future<String> generate({DbmlProgressCallback? onProgress}) async {
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
      final key = (row[0] as String, row[1] as String);
      (grouped[key] ??= <String>[]).add(row[2] as String);
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
      final attrStr = attrs.isEmpty ? '' : ' [${attrs.join(', ')}]';
      buf.writeln(' ${_columnName(c.name)} ${_dbmlType(c)}$attrStr');
    }
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
      buf.writeln('Ref: $from > $to');
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
    return '"${s.replaceAll('"', '\\"')}"';
  }

  String _escapeBacktick(String s) => s.replaceAll('`', r'\`');
}
