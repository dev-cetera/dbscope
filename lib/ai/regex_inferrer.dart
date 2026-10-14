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
  /// Longest sample cell value (in characters) sent to the model.
  static const _kMaxSampleValueLength = 60;

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

    const system =
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
    for (final column in columns) {
      if (column.name == picked) return column.name;
    }
    // LLM may have lowercased / camelised; do a case-insensitive lookup.
    final lower = picked.toLowerCase();
    for (final column in columns) {
      if (column.name.toLowerCase() == lower) return column.name;
    }
    return null;
  }

  static String _buildUserMessage(
    String term,
    List<ColumnInfo> columns,
    List<List<Object?>> sampleRows,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('Pattern: $term');
    buffer.writeln('Columns:');
    for (final column in columns) {
      final type = column.typeName.isEmpty ? 'unknown' : column.typeName;
      buffer.writeln(' - ${column.name} ($type)');
    }
    if (sampleRows.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Sample rows:');
      for (final row in sampleRows) {
        final parts = <String>[];
        for (var i = 0; i < columns.length && i < row.length; i++) {
          final value = row[i];
          if (value == null) continue;
          var text = value.toString();
          if (text.length > _kMaxSampleValueLength) {
            text = '${text.substring(0, _kMaxSampleValueLength - 3)}…';
          }
          parts.add('${columns[i].name}=$text');
        }
        if (parts.isNotEmpty) buffer.writeln(' - ${parts.join(', ')}');
      }
    }
    return buffer.toString();
  }
}
