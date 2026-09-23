// Given a search term and a few sample rows from a table, ask the
// configured LLM which column the term most likely matches.
//
// Privacy: the sample rows are real data. The inferrer only fires when
// the user explicitly opts in via `AiSettings.allowSampleRows` AND
// either leaves the column unselected or picks the explicit "AI Infer"
// sentinel. Never called on every keystroke — only on an explicit
// trigger from the UI.

import '../catalog/schema_catalog.dart';
import 'ai_key_resolver.dart';
import 'provider.dart';
import 'settings_store.dart';
import 'sql_assistant.dart' show AssistantException;

class RegexInferrer {
  /// Returns the inferred column name, or null when the model declined.
  static Future<String?> infer({
    required String term,
    required List<ColumnInfo> columns,
    required List<List<Object?>> sampleRows,
  }) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty) return null;
    if (columns.isEmpty) return null;
    final settings = await AiSettingsStore.instance.load();
    if (!settings.allowSampleRows) {
      throw const AssistantException(
        'AI Infer needs sample-rows opt-in. Enable it in AI ▸ Settings…',
      );
    }
    final providerId = settings.providerId;
    if (providerId == null) {
      throw const AssistantException(
        'No AI provider configured. Open AI ▸ Settings…',
      );
    }
    final provider = AiBrokerRegistry.instance.lookup(providerId);
    if (provider == null) {
      throw AssistantException('Provider "$providerId" no longer available.');
    }
    final apiKey = await AiKeyResolver.resolve(providerId);
    if (apiKey.isEmpty) {
      throw const AssistantException('No API key set for the active provider.');
    }
    // "Auto" mode mirrors SqlAssistant — pick the first available model
    // if the user didn't save a specific one.
    var model = settings.model;
    if (model == null) {
      final models = await provider.listModels(apiKey);
      if (models.isEmpty) {
        throw const AssistantException(
          'Provider returned no models. Check the API key in AI ▸ Settings…',
        );
      }
      model = models.first;
    }

    final system =
        'You decide which column of a database table a regex '
        'pattern is most likely meant to match. Reply with ONLY the '
        'column name — no prose, no quotes, no backticks. If no column '
        'is a plausible match, reply with the single word NONE.';
    final user = _buildUserMessage(trimmed, columns, sampleRows);
    final raw = await provider.complete(
      apiKey: apiKey,
      model: model,
      system: system,
      user: user,
    );
    final picked = raw.trim().replaceAll(RegExp(r'^[`"\s]+|[`"\s]+$'), '');
    if (picked.isEmpty || picked.toUpperCase() == 'NONE') return null;
    // Defence in depth: only trust names that exist.
    for (final c in columns) {
      if (c.name == picked) return c.name;
    }
    // LLM may have lowercased / camelised; do a case-insensitive lookup.
    final lower = picked.toLowerCase();
    for (final c in columns) {
      if (c.name.toLowerCase() == lower) return c.name;
    }
    return null;
  }

  static String _buildUserMessage(
    String term,
    List<ColumnInfo> columns,
    List<List<Object?>> sampleRows,
  ) {
    final buf = StringBuffer();
    buf.writeln('Pattern: $term');
    buf.writeln('Columns:');
    for (final c in columns) {
      final type = c.typeName.isEmpty ? 'unknown' : c.typeName;
      buf.writeln(' - ${c.name} ($type)');
    }
    if (sampleRows.isNotEmpty) {
      buf.writeln();
      buf.writeln('Sample rows:');
      for (final row in sampleRows) {
        final parts = <String>[];
        for (var i = 0; i < columns.length && i < row.length; i++) {
          final v = row[i];
          if (v == null) continue;
          var s = v.toString();
          if (s.length > 60) s = '${s.substring(0, 57)}…';
          parts.add('${columns[i].name}=$s');
        }
        if (parts.isNotEmpty) buf.writeln(' - ${parts.join(', ')}');
      }
    }
    return buf.toString();
  }
}
