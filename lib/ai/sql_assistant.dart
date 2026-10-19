// Natural-language → SQL assistant. Builds a schema summary from the
// active connection's catalog, asks the configured LLM for a query, and
// runs the result through a lexical read-only gate before returning.
//
// The gate is the security boundary — the LLM *will* emit DML when
// pushed; we reject anything whose first token isn't SELECT/WITH/EXPLAIN
// /VALUES. Connection-level read-only (PRAGMA query_only / SET
// default_transaction_read_only) isn't available on every backend (e.g.
// the sqflite-remote plugin), so the gate is the only line of defence.

import '../catalog/dbml_cache.dart';
import '../catalog/schema_catalog.dart';
import '../db/executor.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import '../meta/meta_sources.dart';
import '../meta/selector.dart';
import '../util/sql_parse.dart';
import 'ai_key_resolver.dart';
import 'provider.dart';
import 'settings_store.dart';

class SqlAssistant {
  SqlAssistant(this.conn, {this.profileId});
  final DbExecutor conn;

  /// Profile id used to look up the cached DBML schema. Optional —
  /// callers without a profile context fall back to the naive
  /// catalog-walk in [_fallbackSchemaContext].
  final String? profileId;

  /// Asks the LLM for a query. Returns the cleaned SQL on success; raises
  /// [AssistantException] on configuration / safety problems.
  ///
  /// [focusSchema] / [focusTable] tell the assistant which table the
  /// user is currently looking at — passed through as a hint in the
  /// system prompt so the generated SQL targets it instead of an
  /// unrelated table the AI happens to like.
  Future<String> askSql(
    String prompt, {
    String? focusSchema,
    String? focusTable,
  }) async {
    // Access control: the assistant sends the schema to an AI provider and
    // writes free SQL, so it needs both capabilities.
    final policy = MetadataCache.instance.policyForExecutor(conn);
    if (!policy.can(Capability.ai) || !policy.can(Capability.query)) {
      throw const AssistantException(
        'Your role on this connection cannot use the AI SQL assistant '
        '(it needs the ai and query capabilities).',
      );
    }
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      throw const AssistantException('Empty prompt.');
    }
    final settings = await AiSettingsStore.instance.load();
    final providerId = settings.providerId;
    if (providerId == null) {
      throw const AssistantException(
        'No AI provider configured. Open AI ▸ Settings… first.',
      );
    }
    final provider = AiBrokerRegistry.instance.lookup(providerId);
    if (provider == null) {
      throw AssistantException('Provider "$providerId" no longer available.');
    }
    final apiKey = await AiKeyResolver.resolve(providerId);
    if (apiKey.isEmpty) {
      throw const AssistantException(
        'API key missing. Open AI ▸ Settings… and paste a key, or '
        'export it in your shell env file (File ▸ Environment…).',
      );
    }
    // "Auto" mode: when no specific model is saved, ask the provider
    // for its model list and use the first one. One extra round-trip
    // per call — acceptable for "Ask AI" which is user-initiated and
    // already async. Falls back to the saved model when present.
    final model = settings.model ?? await _autoPickModel(provider, apiKey);

    final schema = await buildSchemaContext();
    final system = _systemPrompt(conn.kind) + _metadataNotes();
    final focus = (focusSchema != null && focusTable != null)
        ? '\n\nFocus table: "$focusSchema"."$focusTable". The user is '
              'currently looking at this table. Prefer to answer against it '
              'unless the request clearly involves a different table.\n'
        : '\n';
    final user = 'Schema:\n$schema$focus\nRequest: $trimmed';
    final raw = await provider.complete(
      apiKey: apiKey,
      model: model,
      system: system,
      user: user,
    );
    final cleaned = _extractSql(raw);
    enforceReadOnly(cleaned, dialect: sqlDialectOf(conn));
    return cleaned;
  }

  static Future<String> _autoPickModel(
    AiBroker provider,
    String apiKey,
  ) async {
    final models = await provider.listModels(apiKey);
    if (models.isEmpty) {
      throw const AssistantException(
        'Provider returned no models. Check the API key in AI ▸ Settings…',
      );
    }
    return models.first;
  }

  /// Builds the schema summary the LLM gets as context. Strategy:
  ///
  /// 1. If a profileId is set and the DBML cache has a ready value,
  /// use it — full PK/FK relationships in a structured, well-known
  /// format the LLMs handle well.
  /// 2. If the cache has a pending generation, await it (the registry
  /// warms it on connect, so first Ask AI may still wait briefly).
  /// 3. Otherwise fall back to a naive catalog-walk so the feature
  /// still works on connections that never warmed (or hit an error
  /// during warm).
  Future<String> buildSchemaContext({int maxTables = 50}) async {
    final pid = profileId;
    if (pid != null) {
      final cached = DbmlCache.instance.peek(pid);
      if (cached != null) return cached;
      try {
        return await DbmlCache.instance.get(pid, conn);
      } catch (_) {
        // Fall through to the naive walk.
      }
    }
    return _fallbackSchemaContext(maxTables: maxTables);
  }

  Future<String> _fallbackSchemaContext({int maxTables = 50}) async {
    final catalog = SchemaCatalog(conn);
    final schemas = await catalog.listSchemas();
    final buffer = StringBuffer();
    var tableBudget = maxTables;
    for (final schema in schemas) {
      if (schema.isSystem) continue;
      final tables = await catalog.listTables(schema.name);
      for (final table in tables) {
        if (tableBudget <= 0) {
          buffer.writeln('(…more tables omitted)');
          return buffer.toString();
        }
        tableBudget--;
        final columns = await catalog.listColumns(schema.name, table.name);
        final columnDescriptions = columns
            .map(
              (column) =>
                  column.typeName.isEmpty ? column.name : '${column.name}:${column.typeName}',
            )
            .join(', ');
        buffer.writeln('${schema.name}.${table.name}($columnDescriptions)');
      }
    }
    return buffer.toString();
  }

  /// `ai` rows from the schema metadata: free-text notes and example
  /// question → SQL pairs, appended to the system prompt.
  String _metadataNotes() {
    final snapshot = MetadataCache.instance.snapshotForExecutor(conn);
    if (snapshot == null) return '';
    final policy = snapshot.policy;
    // Notes aimed at objects this viewer can't see would leak their names
    // (and the AI could echo them back); keep only notes whose target is
    // global, or names a table/column the viewer can at least see.
    bool visible(String target) {
      final selector = Selector.tryParse(target);
      if (selector == null) return false;
      final column = selector.exactColumn;
      if (column != null) {
        return !policy.forColumn(column.schema, column.table, column.column).isNone;
      }
      final table = selector.exactTable;
      if (table != null) {
        return !policy.forTable(table.schema, table.table).isNone;
      }
      return true;
    }

    final notes = [
      for (final note in snapshot.index.aiNotes())
        if (visible(note.target)) note,
    ];
    if (notes.isEmpty) return '';
    final buffer = StringBuffer('\n\nNotes from the schema owner:\n');
    for (final note in notes) {
      if (note.spec.notes != null) {
        buffer.writeln('- (${note.target}) ${note.spec.notes}');
      }
      for (final e in note.spec.examples) {
        buffer.writeln('- Example. Q: ${e.ask}\n  SQL: ${e.sql}');
      }
    }
    return buffer.toString();
  }

  String _systemPrompt(String kind) {
    final dialect = switch (kind) {
      'sqlite' => 'SQLite',
      _ => 'PostgreSQL',
    };
    return 'You translate plain-English questions into a single $dialect '
        'query. Hard rules:\n'
        ' 1. Reply with raw SQL only. No prose, no markdown fences, no '
        'leading comments.\n'
        ' 2. The query MUST be read-only. SELECT / WITH / VALUES / '
        'EXPLAIN only. Never INSERT/UPDATE/DELETE/MERGE/DROP/ALTER/'
        'CREATE/TRUNCATE/GRANT.\n'
        ' 3. Exactly one statement; no trailing semicolons; no second '
        'statement after a semicolon.\n'
        ' 4. Prefer fully-qualified table names from the schema list. '
        'If a name is ambiguous, ask for clarification by emitting `-- '
        'CLARIFY: <question>` on a single line instead of a query.';
  }

  /// Strip markdown fences, leading prose, trailing semicolons.
  String _extractSql(String raw) {
    var sql = raw.trim();
    // Pull contents out of ```sql ... ``` fences if present.
    final fence = RegExp(r'```(?:sql)?\s*(.*?)```', dotAll: true);
    final match = fence.firstMatch(sql);
    if (match != null) {
      sql = match.group(1)!.trim();
    }
    // Drop any leading "Here's the query:" style preamble before the
    // first SQL keyword. The regex looks for SELECT/WITH/etc. and
    // discards anything before it.
    final firstKeyword = RegExp(
      r'\b(SELECT|WITH|EXPLAIN|VALUES)\b',
      caseSensitive: false,
    );
    final keywordMatch = firstKeyword.firstMatch(sql);
    if (keywordMatch != null && keywordMatch.start > 0) {
      sql = sql.substring(keywordMatch.start);
    }
    if (sql.endsWith(';')) {
      sql = sql.substring(0, sql.length - 1).trim();
    }
    return sql.trim();
  }
}

/// Lexical gate. Public so tests / callers can verify directly. Throws
/// [AssistantException] when the SQL is not a single read-only statement.
void enforceReadOnly(String sql, {required SqlDialect dialect}) {
  final stripped = stripCommentsAndLeading(sql, dialect: dialect);
  if (stripped.isEmpty) {
    throw const AssistantException('Empty SQL after stripping comments.');
  }
  if (containsMultipleStatements(stripped, dialect: dialect)) {
    throw const AssistantException(
      'AI returned multiple statements; refusing.',
    );
  }
  final firstWord = _firstWord(stripped).toUpperCase();
  const allowed = {'SELECT', 'WITH', 'EXPLAIN', 'VALUES'};
  if (!allowed.contains(firstWord)) {
    throw AssistantException(
      'AI returned non-read-only SQL ($firstWord); refusing.',
    );
  }
}

String _firstWord(String sql) {
  final match = RegExp('^[A-Za-z_]+').firstMatch(sql);
  return match?.group(0) ?? '';
}

class AssistantException implements Exception {
  const AssistantException(this.message);
  final String message;
  @override
  String toString() => message;
}
