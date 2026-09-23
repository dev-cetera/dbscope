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
  static final ProjectStore instance = ProjectStore._();

  static const String fileName = 'default.dbscopeproj';
  static const String _appDirName = 'dbscopeproj';

  File? _file;
  ProjectDocument _doc = ProjectDocument();
  bool _loaded = false;
  Future<void>? _writeQueue;

  Future<File> _resolveFile() async {
    if (_file != null) return _file!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_appDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    _file = File('${dir.path}/$fileName');
    return _file!;
  }

  Future<Directory> appDir() async {
    await _resolveFile();
    return _file!.parent;
  }

  Future<ProjectDocument> load() async {
    if (_loaded) return _doc;
    final file = await _resolveFile();
    if (!await file.exists()) {
      _doc = ProjectDocument();
      await _writeNow();
    } else {
      try {
        final raw = await file.readAsString();
        _doc = raw.trim().isEmpty
            ? ProjectDocument()
            : ProjectDocument.fromJson(jsonDecode(raw) as Map<String, Object?>);
      } catch (_) {
        // Corrupt file: keep an empty doc rather than crashing. The
        // user can rebuild by re-adding connections; the old broken
        // file stays on disk for forensics.
        _doc = ProjectDocument();
      }
    }
    _loaded = true;
    return _doc;
  }

  Future<void> _writeNow() async {
    final file = await _resolveFile();
    await file.writeAsString(
      const JsonEncoder.withIndent(' ').convert(_doc.toJson()),
      flush: true,
    );
  }

  Future<void> _mutate(void Function(ProjectDocument doc) fn) async {
    final prev = _writeQueue;
    final task = () async {
      try {
        await prev;
      } catch (_) {}
      // Re-read disk so another isolate's update to a different slice
      // is preserved.
      await _resolveFile();
      try {
        if (await _file!.exists()) {
          final raw = await _file!.readAsString();
          if (raw.trim().isNotEmpty) {
            _doc = ProjectDocument.fromJson(
              jsonDecode(raw) as Map<String, Object?>,
            );
          }
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

  // ---- Accessors used by the facade stores ---------------------------

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
