import 'dart:io';

import 'shell_env_io.dart';

Future<void> writeTextFile(String path, String content) =>
    File(path).writeAsString(content, flush: true);

/// Process environment first, then the user's shell env file — see
/// [ShellEnv] for why a GUI-launched app can't just read
/// `Platform.environment`.
String? envValue(String key) => ShellEnv.instance.value(key);
