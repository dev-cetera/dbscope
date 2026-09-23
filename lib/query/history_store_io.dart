import 'dart:convert';
import 'dart:io';

import '../project/project_store.dart';
import 'history_models.dart';

export 'history_models.dart';

/// Saved queries / saved AI queries delegate to [ProjectStore] (they
/// live inside the `.dbscopeproj` document). Per-connection run history
/// is auto-generated noise we don't want bloating the portable project
/// file, so it stays as a sibling JSON file next to the project file.
class HistoryStore {
  HistoryStore._();
  static final HistoryStore instance = HistoryStore._();

  Future<File> _historyFile(String connectionId) async {
    final dir = await ProjectStore.instance.appDir();
    return File('${dir.path}/history_$connectionId.json');
  }

  Future<List<HistoryEntry>> loadHistory(String connectionId) async {
    final file = await _historyFile(connectionId);
    if (!await file.exists()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final list = jsonDecode(raw) as List<Object?>;
    return [
      for (final e in list)
        if (e is Map<String, Object?>) HistoryEntry.fromJson(e),
    ];
  }

  Future<void> appendHistory(String connectionId, String sql) async {
    final existing = await loadHistory(connectionId);
    existing.insert(0, HistoryEntry(sql, DateTime.now()));
    final trimmed = existing.take(200).toList();
    final file = await _historyFile(connectionId);
    await file.writeAsString(
      jsonEncode([for (final e in trimmed) e.toJson()]),
    );
  }

  Future<List<SavedQuery>> loadSaved(String connectionId) async {
    final doc = await ProjectStore.instance.load();
    return List<SavedQuery>.from(doc.savedQueries[connectionId] ?? const []);
  }

  Future<void> saveSaved(String connectionId, List<SavedQuery> queries) =>
      ProjectStore.instance.setSavedQueries(connectionId, queries);

  Future<List<SavedAiQuery>> loadSavedAi(String connectionId) async {
    final doc = await ProjectStore.instance.load();
    return List<SavedAiQuery>.from(
      doc.savedAiQueries[connectionId] ?? const [],
    );
  }

  Future<void> saveSavedAi(
    String connectionId,
    List<SavedAiQuery> queries,
  ) => ProjectStore.instance.setSavedAiQueries(connectionId, queries);
}
