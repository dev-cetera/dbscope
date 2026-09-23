// Pure-dart data classes for query history and saved queries. Kept
// separate from history_store.dart so both the dart:io-backed desktop
// store and the SharedPreferences-backed web store can share identical
// model types (avoids type-identity issues at consumer sites).

class HistoryEntry {
  final String sql;
  final DateTime ranAt;
  HistoryEntry(this.sql, this.ranAt);

  Map<String, Object?> toJson() => {
    'sql': sql,
    'ranAt': ranAt.toIso8601String(),
  };
  static HistoryEntry fromJson(Map<String, Object?> json) => HistoryEntry(
    json['sql'] as String,
    DateTime.parse(json['ranAt'] as String),
  );
}

class SavedQuery {
  final String id;
  final String name;
  final String sql;
  SavedQuery({required this.id, required this.name, required this.sql});

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'sql': sql};
  static SavedQuery fromJson(Map<String, Object?> json) => SavedQuery(
    id: json['id'] as String,
    name: json['name'] as String,
    sql: json['sql'] as String,
  );
}

/// A named save of an AI query: the natural-language prompt, the
/// generated SQL at save time, and the optional schema/table focus.
/// Re-opening yields a fresh AI tab seeded with these values so the
/// user can re-run or re-ask.
class SavedAiQuery {
  final String id;
  final String name;
  final String prompt;
  final String? generatedSql;
  final String? focusSchema;
  final String? focusTable;

  SavedAiQuery({
    required this.id,
    required this.name,
    required this.prompt,
    this.generatedSql,
    this.focusSchema,
    this.focusTable,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'generatedSql': generatedSql,
    'focusSchema': focusSchema,
    'focusTable': focusTable,
  };

  static SavedAiQuery fromJson(Map<String, Object?> json) => SavedAiQuery(
    id: json['id'] as String,
    name: json['name'] as String,
    prompt: (json['prompt'] as String?) ?? '',
    generatedSql: json['generatedSql'] as String?,
    focusSchema: json['focusSchema'] as String?,
    focusTable: json['focusTable'] as String?,
  );
}
