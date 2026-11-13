// The agent's database tools. All of them read; none can write:
//
// * The catalog comes through the policy-filtered SchemaCatalog, so hidden
//   tables and columns never reach the model.
// * Queries pass enforceReadOnly (the lexical gate the SQL assistant uses)
//   and then run fenced in a read-only transaction (QueryRunner.runSql with
//   readOnly), the same path as AI-generated SQL in a query tab. Backends
//   that can't fence (pg-proxy, on-device SQLite) rely on the gate alone.
// * Row values reach the model only when the user turned on "Send sample
//   rows to the AI" in AI ▸ Settings…; otherwise it sees column names and
//   counts.

import '../ai/provider.dart';
import '../ai/sql_assistant.dart' show enforceReadOnly;
import '../catalog/schema_catalog.dart';
import '../db/executor.dart';
import '../meta/meta_sources.dart' show sqlDialectOf;
import '../query/cancel_token.dart';
import '../query/runner.dart';
import 'agent_session.dart';

/// Most tables `db_list_tables` lists.
const _kMaxListedTables = 300;

/// Most rows of a query result handed to the model.
const _kMaxSentRows = 50;

/// Longest cell value handed to the model, in characters.
const _kMaxSentValueLength = 120;

/// Argument names the tools' schemas declare and their runners read.
abstract final class _Args {
  static const schema = 'schema';
  static const table = 'table';
  static const sql = 'sql';
  static const title = 'title';
}

/// The database tools for one connection. [canQuery] is whether the user's
/// role may run free SQL (the `query` capability); without it only the
/// catalog tools are offered. [sendRows] is the user's sample-rows opt-in.
/// [showQuery] opens SQL in a query tab for the user to run.
List<AgentTool> databaseTools({
  required DbExecutor executor,
  required bool canQuery,
  required bool sendRows,
  required CancelToken cancelToken,
  required void Function(String sql, String? title) showQuery,
}) {
  final dialect = sqlDialectOf(executor);
  return [
    AgentTool(
      definition: const AiTool(
        name: 'db_list_tables',
        description:
            'Lists the tables and views in the database, as schema.table '
            'with an estimated row count.',
        inputSchema: {'type': 'object', 'properties': <String, Object?>{}},
      ),
      run: (_) => _listTables(SchemaCatalog(executor)),
    ),
    AgentTool(
      definition: const AiTool(
        name: 'db_describe_table',
        description:
            'Describes one table: its columns with types and nullability, '
            'its primary key, and its foreign keys in and out.',
        inputSchema: {
          'type': 'object',
          'properties': {
            _Args.schema: {'type': 'string'},
            _Args.table: {'type': 'string'},
          },
          'required': [_Args.schema, _Args.table],
        },
      ),
      run: (arguments) => _describeTable(
        SchemaCatalog(executor),
        _string(arguments, _Args.schema),
        _string(arguments, _Args.table),
      ),
    ),
    if (canQuery) ...[
      AgentTool(
        definition: AiTool(
          name: 'db_run_query',
          description:
              'Runs one read-only query (SELECT, WITH, VALUES or EXPLAIN) and '
              'returns its columns and row count'
              '${sendRows ? ', and up to $_kMaxSentRows rows' : ' (row values are withheld by the user)'}. '
              'Anything that writes is refused.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              _Args.sql: {'type': 'string'},
            },
            'required': [_Args.sql],
          },
        ),
        run: (arguments) async {
          final sql = _string(arguments, _Args.sql);
          enforceReadOnly(sql, dialect: dialect);
          final result = await QueryRunner(executor).runSql(
            sql,
            cancelToken: cancelToken,
            readOnly: true,
          );
          return describeQueryResult(result, sendRows: sendRows);
        },
      ),
      AgentTool(
        definition: const AiTool(
          name: 'db_show_query',
          description:
              'Opens a read-only query in a new query tab so the user can see '
              'the full result in the grid and run it. Use it when the user '
              'wants to look at data rather than hear about it.',
          inputSchema: {
            'type': 'object',
            'properties': {
              _Args.sql: {'type': 'string'},
              _Args.title: {'type': 'string', 'description': 'A short tab title.'},
            },
            'required': [_Args.sql],
          },
        ),
        run: (arguments) async {
          final sql = _string(arguments, _Args.sql);
          enforceReadOnly(sql, dialect: dialect);
          final title = arguments[_Args.title];
          showQuery(sql, title is String && title.trim().isNotEmpty ? title.trim() : null);
          return 'Opened a query tab with that SQL. The user presses Run to see it.';
        },
      ),
    ],
  ];
}

/// A required string argument. The model wrote it, so it is checked here.
String _string(Map<String, Object?> arguments, String name) {
  final value = arguments[name];
  if (value is! String || value.trim().isEmpty) {
    throw ArgumentError('"$name" must be a non-empty string.');
  }
  return value.trim();
}

Future<String> _listTables(SchemaCatalog catalog) async {
  final lines = <String>[];
  for (final schema in await catalog.listSchemas()) {
    if (schema.isSystem) continue;
    for (final table in await catalog.listTables(schema.name)) {
      if (lines.length == _kMaxListedTables) {
        lines.add('… more tables not listed');
        return lines.join('\n');
      }
      final rows = table.estimatedRows < 0 ? '' : ' (~${table.estimatedRows} rows)';
      lines.add('${table.schema}.${table.name} ${table.kind}$rows');
    }
  }
  return lines.isEmpty ? 'No tables you can see.' : lines.join('\n');
}

Future<String> _describeTable(SchemaCatalog catalog, String schema, String table) async {
  final columns = await catalog.listColumns(schema, table);
  if (columns.isEmpty) {
    throw ArgumentError('No table "$schema"."$table" you can see.');
  }
  final primaryKey = await catalog.primaryKey(schema, table);
  final foreignKeys = await catalog.listForeignKeys();
  final buffer = StringBuffer('Table $schema.$table\nColumns:\n');
  for (final column in columns) {
    buffer.writeln(
      ' - ${column.name} ${column.typeName}${column.nullable ? '' : ' NOT NULL'}'
      '${column.enumValues == null ? '' : ' one of ${column.enumValues!.join(', ')}'}',
    );
  }
  if (primaryKey.isNotEmpty) buffer.writeln('Primary key: ${primaryKey.join(', ')}');
  for (final key in foreignKeys) {
    if (key.fromSchema == schema && key.fromTable == table) {
      buffer.writeln('References: ${key.fromColumn} → ${key.toSchema}.${key.toTable}.${key.toColumn}');
    } else if (key.toSchema == schema && key.toTable == table) {
      buffer.writeln('Referenced by: ${key.fromSchema}.${key.fromTable}.${key.fromColumn} → ${key.toColumn}');
    }
  }
  return buffer.toString();
}

/// What the model is told about a query result: columns, row count, and
/// the first rows only when [sendRows].
String describeQueryResult(QueryRunResult result, {required bool sendRows}) {
  final data = result.data;
  final buffer = StringBuffer()
    ..writeln('Columns: ${[for (final column in data.columns) column.name].join(', ')}')
    ..writeln('Rows: ${data.rows.length}${result.truncated ? ' (stopped at the row limit)' : ''}');
  if (!sendRows) {
    buffer.writeln(
      'Row values are withheld: the user has not allowed sending rows to the '
      'AI (AI ▸ Settings…). Answer from the counts, or use db_show_query.',
    );
    return buffer.toString();
  }
  for (final row in data.rows.take(_kMaxSentRows)) {
    buffer.writeln([for (final value in row) _cell(value)].join(' | '));
  }
  if (data.rows.length > _kMaxSentRows) {
    buffer.writeln('… ${data.rows.length - _kMaxSentRows} more rows not shown');
  }
  return buffer.toString();
}

String _cell(Object? value) {
  if (value == null) return 'NULL';
  final text = value.toString().replaceAll('\n', ' ');
  return text.length <= _kMaxSentValueLength ? text : '${text.substring(0, _kMaxSentValueLength)}…';
}
