import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../ai/provider.dart';
import '../query/history_models.dart';
import 'project_models.dart';

export 'project_models.dart';

/// Singleton owner of the local `.dbscopeproj` file. Holds the project
/// document in memory and persists it on every mutation.
///
/// Cross-isolate writes (subwindow + host both touching saved queries
/// or AI settings) are handled by re-reading the file inside each
/// mutation, so a sibling isolate's update to a different slice
/// survives. Within an isolate, writes are serialized via [_writeQueue]
/// to avoid interleaving reads-before-writes.
class ProjectStore {
  ProjectStore._();
  static final instance = ProjectStore._();

  static const fileName = 'default.dbscopeproj';
  static const _appDirectoryName = 'dbscopeproj';

  File? _file;
  var _document = ProjectDocument();
  var _loaded = false;
  Future<void>? _writeQueue;

  Future<File> _resolveFile() async {
    if (_file != null) return _file!;
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/$_appDirectoryName');
    if (!directory.existsSync()) await directory.create(recursive: true);
    _file = File('${directory.path}/$fileName');
    return _file!;
  }

  Future<Directory> appDir() async {
    await _resolveFile();
    return _file!.parent;
  }

  Future<ProjectDocument> load() async {
    if (_loaded) return _document;
    final file = await _resolveFile();
    if (!file.existsSync()) {
      _document = ProjectDocument();
      await _writeNow();
    } else {
      try {
        final raw = await file.readAsString();
        _document = raw.trim().isEmpty
            ? ProjectDocument()
            : ProjectDocument.fromJson(jsonDecode(raw) as Map<String, Object?>);
      } catch (_) {
        // Corrupt file: keep an empty doc rather than crashing. The
        // user can rebuild by re-adding connections; the old broken
        // file stays on disk for forensics.
        _document = ProjectDocument();
      }
    }
    _loaded = true;
    return _document;
  }

  Future<void> _writeNow() async {
    final file = await _resolveFile();
    await file.writeAsString(
      const JsonEncoder.withIndent(' ').convert(_document.toJson()),
      flush: true,
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
      // Re-read disk so another isolate's update to a different slice
      // is preserved.
      await _resolveFile();
      try {
        if (_file!.existsSync()) {
          final raw = await _file!.readAsString();
          if (raw.trim().isNotEmpty) {
            _document = ProjectDocument.fromJson(
              jsonDecode(raw) as Map<String, Object?>,
            );
          }
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

  // ---- Accessors used by the facade stores ---------------------------

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
