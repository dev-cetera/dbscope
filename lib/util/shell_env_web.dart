/// Web stub. There is no shell and no filesystem in a browser, so every
/// lookup misses and the UI that would configure a file says so.
enum ShellEnvStatus { notLoaded, loaded, missing, unreadable, unsupported }

/// See `shell_env_io.dart` for what this does on desktop.
class ShellEnv {
  ShellEnv._();
  static final ShellEnv instance = ShellEnv._();

  static const bool isSupported = false;
  static String? get defaultPath => null;

  String? get resolvedPath => null;
  ShellEnvStatus get status => ShellEnvStatus.unsupported;
  String? get error => null;
  List<String> get names => const [];

  Future<void> load({String? path}) async {}

  String? value(String key) => null;
  String? fileValue(String key) => null;
}
