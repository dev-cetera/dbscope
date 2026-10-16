// Pure-dart data classes for query history and saved queries. Kept
// separate from history_store.dart so both the dart:io-backed desktop
// store and the SharedPreferences-backed web store can share identical
// model types (avoids type-identity issues at consumer sites).

import 'dart:convert';

/// Parses a stored history list, keeping whatever entries are readable.
/// A hand-edited or otherwise damaged list must not take the whole
/// history (and every later append, which re-reads it) down with it.
List<HistoryEntry> decodeHistory(String raw) {
  if (raw.trim().isEmpty) return [];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return [];
  }
  if (decoded is! List<Object?>) return [];
  return [for (final entry in decoded) ?HistoryEntry._tryFromJson(entry)];
}

class HistoryEntry {
  HistoryEntry(this.sql, this.ranAt);

  static HistoryEntry? _tryFromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final sql = json['sql'];
    final ranAt = json['ranAt'];
    if (sql is! String || ranAt is! String) return null;
    final parsed = DateTime.tryParse(ranAt);
    return parsed == null ? null : HistoryEntry(sql, parsed);
  }

  final String sql;
  final DateTime ranAt;

  Map<String, Object?> toJson() => {
    'sql': sql,
    'ranAt': ranAt.toIso8601String(),
  };
}

class SavedQuery {
  SavedQuery({required this.id, required this.name, required this.sql});

  factory SavedQuery.fromJson(Map<String, Object?> json) => SavedQuery(
    id: json['id']! as String,
    name: json['name']! as String,
    sql: json['sql']! as String,
  );

  final String id;
  final String name;
  final String sql;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'sql': sql};
}

/// A named save of an AI query: the natural-language prompt, the
/// generated SQL at save time, and the optional schema/table focus.
/// Re-opening yields a fresh AI tab seeded with these values so the
/// user can re-run or re-ask.
class SavedAiQuery {
  SavedAiQuery({
    required this.id,
    required this.name,
    required this.prompt,
    this.generatedSql,
    this.focusSchema,
    this.focusTable,
  });

  factory SavedAiQuery.fromJson(Map<String, Object?> json) => SavedAiQuery(
    id: json['id']! as String,
    name: json['name']! as String,
    prompt: (json['prompt'] as String?) ?? '',
    generatedSql: json['generatedSql'] as String?,
    focusSchema: json['focusSchema'] as String?,
    focusTable: json['focusTable'] as String?,
  );

  final String id;
  final String name;
  final String prompt;
  final String? generatedSql;
  final String? focusSchema;
  final String? focusTable;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'generatedSql': generatedSql,
    'focusSchema': focusSchema,
    'focusTable': focusTable,
  };
}
