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
  static final instance = ProjectStore._();

  static const _kStorageKey = 'dbscope.project';

  var _document = ProjectDocument();
  var _loaded = false;
  Future<void>? _writeQueue;

  Never appDir() {
    throw UnsupportedError(
      'appDir() is not supported on the web build.',
    );
  }

  Future<ProjectDocument> load() async {
    if (_loaded) return _document;
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_kStorageKey);
    if (raw == null || raw.trim().isEmpty) {
      _document = ProjectDocument();
      await _writeNow();
    } else {
      try {
        _document = ProjectDocument.fromJson(
          jsonDecode(raw) as Map<String, Object?>,
        );
      } catch (_) {
        // Corrupt — start clean, like the desktop store does.
        _document = ProjectDocument();
      }
    }
    _loaded = true;
    return _document;
  }

  Future<void> _writeNow() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _kStorageKey,
      const JsonEncoder.withIndent(' ').convert(_document.toJson()),
    );
  }

  Future<void> _mutate(
    void Function(ProjectDocument projectDocument) fn,
  ) async {
    final previousWrite = _writeQueue;
    final task = () async {
      try {
        await previousWrite;
      } catch (_) {}
      // Re-read storage in case another tab updated it.
      try {
        final preferences = await SharedPreferences.getInstance();
        final raw = preferences.getString(_kStorageKey);
        if (raw != null && raw.trim().isNotEmpty) {
          _document = ProjectDocument.fromJson(
            jsonDecode(raw) as Map<String, Object?>,
          );
        }
      } catch (_) {
        /* keep prior in-memory doc */
      }
      fn(_document);
      await _writeNow();
    }();
    _writeQueue = task;
    return task;
  }

  ProjectDocument get document => _document;

  Future<void> setProfiles(List<Map<String, Object?>> profiles) =>
      _mutate((projectDocument) => projectDocument.profiles = profiles);

  Future<void> setSavedQueries(
    String connectionId,
    List<SavedQuery> queries,
  ) => _mutate((projectDocument) {
    if (queries.isEmpty) {
      projectDocument.savedQueries.remove(connectionId);
    } else {
      projectDocument.savedQueries[connectionId] = queries;
    }
  });

  Future<void> setSavedAiQueries(
    String connectionId,
    List<SavedAiQuery> queries,
  ) => _mutate((projectDocument) {
    if (queries.isEmpty) {
      projectDocument.savedAiQueries.remove(connectionId);
    } else {
      projectDocument.savedAiQueries[connectionId] = queries;
    }
  });

  Future<void> setAiSettings(AiSettings settings) =>
      _mutate((projectDocument) => projectDocument.ai = settings);
}
