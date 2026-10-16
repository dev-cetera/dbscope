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
  static final instance = HistoryStore._();

  /// How many of the most recent queries are kept per connection.
  static const _kMaxHistoryEntries = 200;

  String _key(String connectionId) => 'dbscope.history.$connectionId';

  Future<List<HistoryEntry>> loadHistory(String connectionId) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key(connectionId));
    return raw == null ? [] : decodeHistory(raw);
  }

  Future<void> appendHistory(String connectionId, String sql) async {
    final existing = await loadHistory(connectionId);
    existing.insert(0, HistoryEntry(sql, DateTime.now()));
    final trimmed = existing.take(_kMaxHistoryEntries).toList();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key(connectionId),
      jsonEncode([for (final e in trimmed) e.toJson()]),
    );
  }

  Future<List<SavedQuery>> loadSaved(String connectionId) async {
    final projectDocument = await ProjectStore.instance.load();
    return List<SavedQuery>.from(
      projectDocument.savedQueries[connectionId] ?? const [],
    );
  }

  Future<void> saveSaved(String connectionId, List<SavedQuery> queries) =>
      ProjectStore.instance.setSavedQueries(connectionId, queries);

  Future<List<SavedAiQuery>> loadSavedAi(String connectionId) async {
    final projectDocument = await ProjectStore.instance.load();
    return List<SavedAiQuery>.from(
      projectDocument.savedAiQueries[connectionId] ?? const [],
    );
  }

  Future<void> saveSavedAi(
    String connectionId,
    List<SavedAiQuery> queries,
  ) => ProjectStore.instance.setSavedAiQueries(connectionId, queries);
}
