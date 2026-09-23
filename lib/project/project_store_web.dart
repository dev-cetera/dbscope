import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../ai/provider.dart';
import '../query/history_models.dart';
import 'project_models.dart';

export 'project_models.dart';

/// Web variant of ProjectStore. Persists the project document as a
/// single JSON string in browser localStorage via SharedPreferences.
/// `appDir()` is unsupported on web (the desktop stores sibling files
/// next to the project file, but on web everything goes through
/// localStorage), so it throws.
class ProjectStore {
  ProjectStore._();
  static final ProjectStore instance = ProjectStore._();

  static const String _kStorageKey = 'dbscope.project';

  ProjectDocument _doc = ProjectDocument();
  bool _loaded = false;
  Future<void>? _writeQueue;

  Never appDir() {
    throw UnsupportedError(
      'appDir() is not supported on the web build.',
    );
  }

  Future<ProjectDocument> load() async {
    if (_loaded) return _doc;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kStorageKey);
    if (raw == null || raw.trim().isEmpty) {
      _doc = ProjectDocument();
      await _writeNow();
    } else {
      try {
        _doc = ProjectDocument.fromJson(
          jsonDecode(raw) as Map<String, Object?>,
        );
      } catch (_) {
        // Corrupt — start clean, like the desktop store does.
        _doc = ProjectDocument();
      }
    }
    _loaded = true;
    return _doc;
  }

  Future<void> _writeNow() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kStorageKey,
      const JsonEncoder.withIndent(' ').convert(_doc.toJson()),
    );
  }

  Future<void> _mutate(void Function(ProjectDocument doc) fn) async {
    final prev = _writeQueue;
    final task = () async {
      try {
        await prev;
      } catch (_) {}
      // Re-read storage in case another tab updated it.
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_kStorageKey);
        if (raw != null && raw.trim().isNotEmpty) {
          _doc = ProjectDocument.fromJson(
            jsonDecode(raw) as Map<String, Object?>,
          );
        }
      } catch (_) {
        /* keep prior in-memory doc */
      }
      fn(_doc);
      await _writeNow();
    }();
    _writeQueue = task;
    return task;
  }

  ProjectDocument get document => _doc;

  Future<void> setProfiles(List<Map<String, Object?>> profiles) =>
      _mutate((d) => d.profiles = profiles);

  Future<void> setSavedQueries(
    String connectionId,
    List<SavedQuery> queries,
  ) => _mutate((d) {
    if (queries.isEmpty) {
      d.savedQueries.remove(connectionId);
    } else {
      d.savedQueries[connectionId] = queries;
    }
  });

  Future<void> setSavedAiQueries(
    String connectionId,
    List<SavedAiQuery> queries,
  ) => _mutate((d) {
    if (queries.isEmpty) {
      d.savedAiQueries.remove(connectionId);
    } else {
      d.savedAiQueries[connectionId] = queries;
    }
  });

  Future<void> setAiSettings(AiSettings settings) =>
      _mutate((d) => d.ai = settings);
}
