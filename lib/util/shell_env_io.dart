import 'dart:io';

/// How the last [ShellEnv.load] went.
enum ShellEnvStatus {
  /// [ShellEnv.load] hasn't run yet.
  notLoaded,

  /// The file was read and parsed (possibly to zero variables).
  loaded,

  /// Nothing at the resolved path.
  missing,

  /// The path exists but couldn't be read.
  unreadable,

  /// No shell env file on this platform, and none configured.
  unsupported,
}

/// Environment variables for a GUI-launched app.
///
/// A desktop app started from Finder — or from an IDE, or by
/// `flutter run` — inherits launchd's minimal environment, not a
/// shell's. None of the `export FOO=bar` lines in the user's shell
/// profile are visible to `Platform.environment`, so a key the user put
/// in `~/.zshenv` reads back as null and the app looks broken for a
/// reason nothing on screen explains.
///
/// [ShellEnv] closes that gap. The process environment still wins;
/// anything missing from it is looked up in a shell env file —
/// `~/.zshenv` by default (the one zsh file *every* shell sources,
/// login or interactive or not), or whatever path the user picked in
/// File ▸ Environment.
///
/// The file is read once at [load] and cached, so [value] stays a cheap
/// synchronous lookup at every call site.
class ShellEnv {
  ShellEnv._();
  static final ShellEnv instance = ShellEnv._();

  /// False only on web, where there is no shell and no filesystem.
  static const bool isSupported = true;

  /// The file consulted when the user hasn't chosen one.
  ///
  /// Null on Windows: there is no zsh convention to guess at, so the
  /// feature stays inert there until an explicit path is set.
  static String? get defaultPath {
    if (Platform.isWindows) return null;
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/.zshenv';
  }

  Map<String, String> _fileVars = const {};
  String? _resolvedPath;
  ShellEnvStatus _status = ShellEnvStatus.notLoaded;
  String? _error;

  /// The file [load] last tried to read, default or user-set.
  String? get resolvedPath => _resolvedPath;

  ShellEnvStatus get status => _status;

  /// Why the last load failed, when [status] is
  /// [ShellEnvStatus.unreadable].
  String? get error => _error;

  /// Names found in the file, sorted. Names only — the values are
  /// API keys and passphrases, and never leave this object except
  /// through [value] and [fileValue].
  List<String> get names => _fileVars.keys.toList()..sort();

  /// Reads and caches [path], or [defaultPath] when [path] is empty.
  ///
  /// Never throws: every failure lands in [status] / [error] so a
  /// missing or malformed profile degrades to "the process environment
  /// only" instead of blocking startup.
  Future<void> load({String? path}) async {
    final trimmed = path?.trim();
    final target = (trimmed == null || trimmed.isEmpty) ? defaultPath : trimmed;
    _resolvedPath = target;
    _error = null;
    if (target == null) {
      _fileVars = const {};
      _status = ShellEnvStatus.unsupported;
      return;
    }
    final file = File(target);
    if (!await file.exists()) {
      _fileVars = const {};
      _status = ShellEnvStatus.missing;
      return;
    }
    try {
      // Parsed into a local and swapped in at the end, never blanked up
      // front: this is a singleton every env lookup in the app reads, and
      // the three awaits below are long enough that a RELOAD would
      // otherwise answer "no such variable" to everything in between.
      final parsed = await parseShellEnv(
        await file.readAsString(),
        readInclude: (includePath) => _readInclude(includePath, file.parent),
      );
      _fileVars = parsed;
      _status = ShellEnvStatus.loaded;
    } catch (e) {
      _fileVars = const {};
      _status = ShellEnvStatus.unreadable;
      _error = '$e';
    }
  }

  /// [Platform.environment] first, the shell file second.
  ///
  /// An empty value counts as absent on both sides: `export FOO=` is
  /// how a shell profile spells "unset", not a meaningful value.
  String? value(String key) {
    final fromProcess = Platform.environment[key];
    if (fromProcess != null && fromProcess.isNotEmpty) return fromProcess;
    final fromFile = _fileVars[key];
    if (fromFile == null || fromFile.isEmpty) return null;
    return fromFile;
  }

  /// The file's own value, ignoring the process environment.
  ///
  /// For keys where the two should be *merged* rather than one winning.
  /// `PATH` is the only such key today — the launchd PATH is real, it's
  /// just missing the Homebrew and SDK directories the shell PATH adds.
  String? fileValue(String key) => _fileVars[key];

  /// Follows one `source` / `.` line. Relative paths resolve against the
  /// including file's directory — a GUI app's working directory is
  /// meaningless, so the shell's own `$PWD` rule would be worse than
  /// useless here.
  static Future<String?> _readInclude(String path, Directory parent) async {
    final absolute = path.startsWith('/')
        ? path
        : '${parent.path}${Platform.pathSeparator}$path';
    final file = File(absolute);
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }
}

/// Parses shell-profile [text] into a variable map layered onto [base].
///
/// Deliberately not a shell. It understands the one line shape that
/// matters — `export NAME=value` / `NAME=value` — plus `source` / `.`
/// includes, and ignores everything else (conditionals, function
/// bodies, command calls), because a profile that needs a real shell to
/// read is a profile we should not be guessing at. Rules:
///
///  - `#` starts a comment at the start of a line, or after whitespace
///    in an unquoted value.
///  - Single-quoted values are literal. Double-quoted and unquoted
///    values expand `$NAME` and `${NAME}` against what is known so far
///    ([base], [Platform.environment], and earlier lines), an unknown
///    name becoming empty the way a shell would.
///  - A later assignment of the same name wins, includes included.
///
/// [readInclude] is how `source` / `.` lines are followed; it returns
/// null for a path that can't be read. Injected so the parser can be
/// tested without touching the filesystem. Includes nest [maxDepth]
/// deep, and a file already visited on this branch is skipped — a
/// profile that sources itself must not hang the app.
Future<Map<String, String>> parseShellEnv(
  String text, {
  Map<String, String> base = const {},
  Future<String?> Function(String path)? readInclude,
  int maxDepth = 4,
  int depth = 0,
  Set<String>? visited,
}) async {
  final vars = <String, String>{...base};
  final seen = visited ?? <String>{};
  for (final line in text.split('\n')) {
    final include = _includeLine.firstMatch(line);
    if (include != null) {
      if (readInclude == null || depth >= maxDepth) continue;
      final path = _unquote(_expand(include.group(1)!.trim(), vars));
      if (path.isEmpty || !seen.add(path)) continue;
      final included = await readInclude(path);
      if (included == null) continue;
      vars.addAll(
        await parseShellEnv(
          included,
          base: vars,
          readInclude: readInclude,
          maxDepth: maxDepth,
          depth: depth + 1,
          visited: seen,
        ),
      );
      continue;
    }
    final assignment = _assignmentLine.firstMatch(line);
    if (assignment == null) continue;
    vars[assignment.group(1)!] = _parseValue(assignment.group(2)!, vars);
  }
  return vars;
}

final _assignmentLine = RegExp(
  r'^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$',
);

final _includeLine = RegExp(r'^[ \t]*(?:source|\.)[ \t]+(\S.*)$');

final _reference = RegExp(
  r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)',
);

String _parseValue(String raw, Map<String, String> vars) {
  final value = raw.trimLeft();
  if (value.startsWith("'")) {
    final end = value.indexOf("'", 1);
    return end == -1 ? value.substring(1) : value.substring(1, end);
  }
  if (value.startsWith('"')) {
    final body = StringBuffer();
    for (var i = 1; i < value.length; i++) {
      final c = value[i];
      if (c == r'\' && i + 1 < value.length) {
        body.write(value[++i]);
        continue;
      }
      if (c == '"') break;
      body.write(c);
    }
    return _expand(body.toString(), vars);
  }
  // Unquoted: a `#` preceded by whitespace starts a trailing comment.
  final comment = RegExp(r'[ \t]#').firstMatch(value);
  final body = comment == null ? value : value.substring(0, comment.start);
  return _expand(body.trimRight(), vars);
}

/// Substitutes `$NAME` / `${NAME}` from [vars], then the process
/// environment, then empty.
String _expand(String value, Map<String, String> vars) {
  if (!value.contains(r'$')) return value;
  return value.replaceAllMapped(_reference, (m) {
    final name = m.group(1) ?? m.group(2)!;
    return vars[name] ?? Platform.environment[name] ?? '';
  });
}

/// Strips one layer of matching surrounding quotes.
String _unquote(String value) {
  final v = value.trim();
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'")))) {
    return v.substring(1, v.length - 1);
  }
  return v;
}
