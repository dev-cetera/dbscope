import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../ai/provider.dart';
import '../query/history_models.dart';
import '../util/file_lock_io.dart';
import 'project_models.dart';

export 'project_models.dart';

/// Singleton owner of the local `.dbscopeproj` file. Holds the project
/// document in memory and persists it on every mutation.
///
/// Cross-isolate writes (subwindow + host both touching saved queries
/// or AI settings): each mutation re-reads the file, applies its change and
/// writes it back while holding a lock file ([withFileLock]), so a sibling
/// isolate's update to a different slice survives. Within an isolate,
/// writes are also serialized via [_writeQueue].
///
/// Writes are atomic (temp file + rename), and a file that fails to parse
/// is moved aside to `default.dbscopeproj.corrupt-<time>` before anything
/// is written over it.
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
      _document = await _readOrPreserve(file) ?? ProjectDocument();
    }
    _loaded = true;
    return _document;
  }

  /// Parses [file]. An empty file reads as an empty document. A file that
  /// fails to parse (a write cut short by a crash or a full disk) is moved
  /// aside, so the empty document that replaces it in memory can't be
  /// written over the only copy, and null is returned.
  Future<ProjectDocument?> _readOrPreserve(File file) async {
    final String raw;
    try {
      raw = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    if (raw.trim().isEmpty) return ProjectDocument();
    try {
      return ProjectDocument.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      preserveCorruptFile(file);
      return null;
    }
  }

  Future<void> _writeNow() async {
    final file = await _resolveFile();
    await writeFileAtomically(
      file,
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
      final file = await _resolveFile();
      // Read, change and write under the cross-isolate lock, so another
      // window's update to a different slice is neither lost nor lost to.
      await withFileLock(file.path, () async {
        if (file.existsSync()) {
          // Unreadable: it has been moved aside; keep the in-memory doc.
          final fresh = await _readOrPreserve(file);
          if (fresh != null) _document = fresh;
        }
        fn(_document);
        await _writeNow();
      });
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
