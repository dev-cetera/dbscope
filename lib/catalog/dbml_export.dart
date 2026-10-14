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
        .where((schema) => !schema.isSystem)
        .toList();

    final allTables = <TableInfo>[];
    for (final schema in schemas) {
      final tables = await catalog.listTables(schema.name);
      allTables.addAll(tables.where((table) => table.kind == 'BASE TABLE'));
    }

    final enums = await _loadEnums(
      schemas.map((schema) => schema.name).toList(),
    );

    final foreignKeys = await catalog.listForeignKeys();

    final buffer = StringBuffer();
    buffer.writeln('Project $databaseName {');
    buffer.writeln(" database_type: 'PostgreSQL'");
    buffer.writeln('}');
    buffer.writeln();

    for (final dbmlEnum in enums) {
      _writeEnum(buffer, dbmlEnum);
      buffer.writeln();
    }

    for (var i = 0; i < allTables.length; i++) {
      final table = allTables[i];
      onProgress?.call(
        DbmlExportProgress(
          completed: i,
          total: allTables.length,
          currentTable: '${table.schema}.${table.name}',
        ),
      );
      final columns = await catalog.listColumns(table.schema, table.name);
      final primaryKey = await catalog.primaryKey(table.schema, table.name);
      _writeTable(buffer, table, columns, primaryKey);
      buffer.writeln();
    }
    onProgress?.call(
      DbmlExportProgress(
        completed: allTables.length,
        total: allTables.length,
        currentTable: '',
      ),
    );

    _writeForeignKeys(buffer, foreignKeys);

    return buffer.toString();
  }

  Future<List<DbmlEnum>> _loadEnums(List<String> schemas) async {
    if (schemas.isEmpty) return const [];
    final params = <Object?>[];
    final placeholders = <String>[];
    for (final schema in schemas) {
      params.add(schema);
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

  void _writeEnum(StringBuffer buffer, DbmlEnum dbmlEnum) {
    buffer.writeln('Enum ${_qualifiedRef(dbmlEnum.schema, dbmlEnum.name)} {');
    for (final value in dbmlEnum.values) {
      buffer.writeln(' ${_quoteIfNeeded(value)}');
    }
    buffer.writeln('}');
  }

  void _writeTable(
    StringBuffer buffer,
    TableInfo table,
    List<ColumnInfo> columns,
    List<String> primaryKey,
  ) {
    final primaryKeySet = primaryKey.toSet();
    final singlePrimaryKey = primaryKey.length == 1 ? primaryKey.first : null;
    buffer.writeln('Table ${_qualifiedRef(table.schema, table.name)} {');
    for (final column in columns) {
      final attributes = <String>[];
      if (singlePrimaryKey == column.name) attributes.add('pk');
      if (column.isIdentity) attributes.add('increment');
      if (!column.nullable && !primaryKeySet.contains(column.name)) {
        attributes.add('not null');
      }
      final defaultExpression = column.defaultExpr;
      if (defaultExpression != null &&
          defaultExpression.toUpperCase() != 'NULL' &&
          !column.isGenerated) {
        attributes.add('default: `${_escapeBacktick(defaultExpression)}`');
      }
      final note = _columnNote(table, column);
      if (note != null) attributes.add("note: '${_escapeNote(note)}'");
      final attributeSuffix = attributes.isEmpty
          ? ''
          : ' [${attributes.join(', ')}]';
      buffer.writeln(
        ' ${_columnName(column.name)} ${_dbmlType(column)}$attributeSuffix',
      );
    }
    final tableNote = _meta
        ?.describeTable(table.schema, table.name)
        .description;
    if (tableNote != null) buffer.writeln(" Note: '${_escapeNote(tableNote)}'");
    if (primaryKey.length > 1) {
      buffer.writeln(' indexes {');
      final keyColumns = primaryKey.map(_columnName).join(', ');
      buffer.writeln(' ($keyColumns) [pk]');
      buffer.writeln(' }');
    }
    buffer.writeln('}');
  }

  void _writeForeignKeys(StringBuffer buffer, List<ForeignKey> foreignKeys) {
    final byConstraint = <String, List<ForeignKey>>{};
    for (final foreignKey in foreignKeys) {
      (byConstraint[foreignKey.constraintKey] ??= <ForeignKey>[]).add(
        foreignKey,
      );
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
      buffer.writeln(
        'Ref: $from > $to${first.isVirtual ? ' // virtual (metadata link)' : ''}',
      );
    }
  }

  String _dbmlType(ColumnInfo column) {
    final name = column.typeName;
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

  bool _isSimpleIdent(String text) {
    if (text.isEmpty) return false;
    final pattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    return pattern.hasMatch(text);
  }

  String _quoteIfNeeded(String text) {
    if (_isSimpleIdent(text)) return text;
    return '"${text.replaceAll('"', r'\"')}"';
  }

  String _escapeBacktick(String text) => text.replaceAll('`', r'\`');

  /// Description + enum meanings for a column, plus a marker when the
  /// viewer only sees it masked.
  String? _columnNote(TableInfo table, ColumnInfo column) {
    final describe = _meta?.describeColumn(
      table.schema,
      table.name,
      column.name,
    );
    final parts = <String>[
      ?describe?.description,
      if (describe?.unit != null) 'unit: ${describe!.unit}',
      if (describe != null && describe.values.isNotEmpty)
        'values: ${describe.values.entries.map((e) => '${e.key} = ${e.value}').join('; ')}',
      if (describe?.deprecated != null) 'deprecated: ${describe!.deprecated}',
      if (column.isMasked) 'masked for this user',
    ];
    return parts.isEmpty ? null : parts.join(' | ');
  }

  String _escapeNote(String text) =>
      text.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', ' ');
}
