import 'dart:io';

import 'shell_env_io.dart';

Future<void> writeTextFile(String path, String content) =>
    File(path).writeAsString(content, flush: true);

/// Process environment first, then the user's shell env file — see
/// [ShellEnv] for why a GUI-launched app can't just read
/// `Platform.environment`.
String? envValue(String key) => ShellEnv.instance.value(key);

/// The process environment only, without the shell env file. For settings
/// that must come from how this one process was launched (e.g.
/// `DBSCOPE_AUTO_*` from a launcher script), not from the user's profile.
Map<String, String> processEnvironment() => Platform.environment;

/// Reads a UTF-8 text file. Throws when the file is missing or unreadable.
Future<String> readTextFile(String path) => File(path).readAsString();

/// Directory part of [path], for resolving relative includes.
String parentDirectory(String path) => File(path).parent.path;

/// Joins [relative] onto [directory] unless it is already absolute.
String resolveRelativePath(String directory, String relative) {
  if (relative.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(relative)) {
    return relative;
  }
  return '$directory${Platform.pathSeparator}$relative';
}
