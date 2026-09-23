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
import '../util/sql_parse.dart';
import 'ai_key_resolver.dart';
import 'provider.dart';
import 'settings_store.dart';

class SqlAssistant {
  final DbExecutor conn;

  /// Profile id used to look up the cached DBML schema. Optional —
  /// callers without a profile context fall back to the naive
  /// catalog-walk in [_fallbackSchemaContext].
  final String? profileId;

  SqlAssistant(this.conn, {this.profileId});

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
    final system = _systemPrompt(conn.kind);
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
    enforceReadOnly(cleaned);
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
    final buf = StringBuffer();
    var tableBudget = maxTables;
    for (final s in schemas) {
      if (s.isSystem) continue;
      final tables = await catalog.listTables(s.name);
      for (final t in tables) {
        if (tableBudget <= 0) {
          buf.writeln('(…more tables omitted)');
          return buf.toString();
        }
        tableBudget--;
        final cols = await catalog.listColumns(s.name, t.name);
        final colDesc = cols
            .map((c) => c.typeName.isEmpty ? c.name : '${c.name}:${c.typeName}')
            .join(', ');
        buf.writeln('${s.name}.${t.name}($colDesc)');
      }
    }
    return buf.toString();
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
    var s = raw.trim();
    // Pull contents out of ```sql ... ``` fences if present.
    final fence = RegExp(r'```(?:sql)?\s*(.*?)```', dotAll: true);
    final match = fence.firstMatch(s);
    if (match != null) {
      s = match.group(1)!.trim();
    }
    // Drop any leading "Here's the query:" style preamble before the
    // first SQL keyword. The regex looks for SELECT/WITH/etc. and
    // discards anything before it.
    final firstKeyword = RegExp(
      r'\b(SELECT|WITH|EXPLAIN|VALUES)\b',
      caseSensitive: false,
    );
    final m = firstKeyword.firstMatch(s);
    if (m != null && m.start > 0) {
      s = s.substring(m.start);
    }
    if (s.endsWith(';')) {
      s = s.substring(0, s.length - 1).trim();
    }
    return s.trim();
  }
}

/// Lexical gate. Public so tests / callers can verify directly. Throws
/// [AssistantException] when the SQL is not a single read-only statement.
void enforceReadOnly(String sql) {
  final stripped = stripCommentsAndLeading(sql);
  if (stripped.isEmpty) {
    throw const AssistantException('Empty SQL after stripping comments.');
  }
  if (containsMultipleStatements(stripped)) {
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
  final m = RegExp(r'^[A-Za-z_]+').firstMatch(sql);
  return m?.group(0) ?? '';
}

class AssistantException implements Exception {
  final String message;
  const AssistantException(this.message);
  @override
  String toString() => message;
}
