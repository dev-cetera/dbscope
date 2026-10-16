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
  static final instance = HistoryStore._();

  /// How many of the most recent queries are kept per connection.
  static const _kMaxHistoryEntries = 200;

  Future<File> _historyFile(String connectionId) async {
    final directory = await ProjectStore.instance.appDir();
    return File('${directory.path}/history_$connectionId.json');
  }

  Future<List<HistoryEntry>> loadHistory(String connectionId) async {
    final file = await _historyFile(connectionId);
    if (!file.existsSync()) return [];
    return decodeHistory(await file.readAsString());
  }

  Future<void> appendHistory(String connectionId, String sql) async {
    final existing = await loadHistory(connectionId);
    existing.insert(0, HistoryEntry(sql, DateTime.now()));
    final trimmed = existing.take(_kMaxHistoryEntries).toList();
    final file = await _historyFile(connectionId);
    // Write-then-rename: a crash or quit mid-write leaves the previous
    // file intact rather than a truncated one.
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode([for (final e in trimmed) e.toJson()]),
      flush: true,
    );
    await temp.rename(file.path);
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
