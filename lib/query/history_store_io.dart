import 'dart:convert';
import 'dart:io';

import '../project/project_store.dart';
import '../util/file_lock_io.dart';
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
    final file = await _historyFile(connectionId);
    final entry = HistoryEntry(sql, DateTime.now());
    // Every window appends to the same file. Read-modify-write under a
    // cross-isolate lock, through a uniquely named temp file, so two
    // windows finishing queries together both keep their entry.
    await withFileLock(file.path, () async {
      final existing = await loadHistory(connectionId);
      existing.insert(0, entry);
      final trimmed = existing.take(_kMaxHistoryEntries).toList();
      await writeFileAtomically(
        file,
        jsonEncode([for (final e in trimmed) e.toJson()]),
      );
    });
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
