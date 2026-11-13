// Given a search term and a few sample rows from a table, ask the
// configured LLM which column the term most likely matches.
//
// Privacy: the sample rows are real data. The inferrer only fires when
// the user explicitly opts in via `AiSettings.allowSampleRows` AND
// either leaves the column unselected or picks the explicit "AI Infer"
// sentinel. Never called on every keystroke — only on an explicit
// trigger from the UI.

import 'dart:convert';

import '../catalog/schema_catalog.dart';
import 'ai_target.dart';
import 'provider.dart';
import 'settings_store.dart';
import 'sql_assistant.dart' show AssistantException;

class RegexInferrer {
  static const _replySchema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['column'],
    'properties': {
      'column': {
        'type': ['string', 'null'],
      },
    },
  };

  /// The column name in the model's JSON reply, or null when it named none.
  static String? _pickedColumn(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(stripCodeFence(raw.trim()));
    } on FormatException {
      throw const AssistantException('AI returned a reply that is not JSON.');
    }
    if (decoded is! Map<String, Object?>) {
      throw const AssistantException('AI returned JSON of the wrong shape.');
    }
    final column = decoded['column'];
    if (column is! String || column.trim().isEmpty) return null;
    return column.trim();
  }

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
    final target = await AiTarget.resolve(settings);
    const system =
        'You decide which column of a database table a regex '
        'pattern is most likely meant to match. Reply with JSON: '
        '{"column": <the column name>}, or {"column": null} if no column '
        'is a plausible match.';
    final user = _buildUserMessage(trimmed, columns, sampleRows);
    final raw = await target.broker.chat(
      apiKey: target.apiKey,
      model: target.model,
      request: ChatRequest(
        system: system,
        messages: [AiMessage.user(user)],
        jsonSchema: _replySchema,
      ),
    );
    final picked = _pickedColumn(raw);
    if (picked == null) return null;
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
