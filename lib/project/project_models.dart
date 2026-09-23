// Pure-dart ProjectDocument. Kept separate from project_store.dart so
// both the dart:io-backed desktop store and the SharedPreferences-backed
// web store share identical model types.

import '../ai/provider.dart';
import '../query/history_models.dart';

/// In-memory project model. Mirrors the JSON shape on disk: profile JSON
/// is kept as raw Maps so this file doesn't depend on the connection
/// layer. Mutators on [ProjectStore] are the only sanctioned way to
/// change a document — direct field writes here will not persist.
class ProjectDocument {
  int version;
  String name;
  List<Map<String, Object?>> profiles;
  Map<String, List<SavedQuery>> savedQueries;
  Map<String, List<SavedAiQuery>> savedAiQueries;
  AiSettings ai;

  ProjectDocument({
    this.version = 1,
    this.name = 'Default Project',
    List<Map<String, Object?>>? profiles,
    Map<String, List<SavedQuery>>? savedQueries,
    Map<String, List<SavedAiQuery>>? savedAiQueries,
    AiSettings? ai,
  }) : profiles = profiles ?? [],
       savedQueries = savedQueries ?? {},
       savedAiQueries = savedAiQueries ?? {},
       ai = ai ?? const AiSettings();

  Map<String, Object?> toJson() => {
    'version': version,
    'name': name,
    'profiles': profiles,
    'savedQueries': {
      for (final e in savedQueries.entries)
        e.key: [for (final q in e.value) q.toJson()],
    },
    'savedAiQueries': {
      for (final e in savedAiQueries.entries)
        e.key: [for (final q in e.value) q.toJson()],
    },
    'ai': ai.toJson(),
  };

  static ProjectDocument fromJson(Map<String, Object?> json) {
    Map<String, List<T>> mapOf<T>(
      Object? raw,
      T Function(Map<String, Object?>) fromJson,
    ) {
      if (raw is! Map<String, Object?>) return {};
      final out = <String, List<T>>{};
      for (final entry in raw.entries) {
        final list = entry.value;
        if (list is! List) continue;
        out[entry.key] = [
          for (final item in list)
            if (item is Map<String, Object?>) fromJson(item),
        ];
      }
      return out;
    }

    return ProjectDocument(
      version: (json['version'] as int?) ?? 1,
      name: (json['name'] as String?) ?? 'Default Project',
      profiles: [
        for (final p in (json['profiles'] as List? ?? const []))
          if (p is Map<String, Object?>) p,
      ],
      savedQueries: mapOf(json['savedQueries'], SavedQuery.fromJson),
      savedAiQueries: mapOf(json['savedAiQueries'], SavedAiQuery.fromJson),
      ai: json['ai'] is Map<String, Object?>
          ? AiSettings.fromJson(json['ai'] as Map<String, Object?>)
          : const AiSettings(),
    );
  }
}
