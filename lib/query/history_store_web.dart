import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../project/project_store.dart';
import 'history_models.dart';

export 'history_models.dart';

/// Web variant of HistoryStore. Run history is stored in
/// SharedPreferences (browser localStorage on the web build); saved
/// queries / saved AI queries delegate to [ProjectStore] like on
/// desktop.
class HistoryStore {
  HistoryStore._();
  static final HistoryStore instance = HistoryStore._();

  String _key(String connectionId) => 'dbscope.history.$connectionId';

  Future<List<HistoryEntry>> loadHistory(String connectionId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(connectionId));
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<Object?>;
      return [
        for (final e in list)
          if (e is Map<String, Object?>) HistoryEntry.fromJson(e),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> appendHistory(String connectionId, String sql) async {
    final existing = await loadHistory(connectionId);
    existing.insert(0, HistoryEntry(sql, DateTime.now()));
    final trimmed = existing.take(200).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(connectionId),
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
