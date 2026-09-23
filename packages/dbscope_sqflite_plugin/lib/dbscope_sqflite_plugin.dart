// On-device SQLite connection plugin for DBScope.
//
// The plugin lets DBScope connect to a SQLite database file living inside
// a Flutter (or any other) app on a USB-connected Android / iOS device.
// File access uses `adb` (Android, debuggable APKs only) and `xcrun
// devicectl` (iOS) via the `app_data_explorer` package. No in-app agent
// or VM service required.
//
// Usage: register the plugin once during app startup —
//
// DbscopePluginRegistry.instance.register(SqfliteRemotePlugin());
//
// Removing this plugin is a four-step cleanup:
// 1. delete this package folder (`packages/dbscope_sqflite_plugin/`)
// 2. remove the `dbscope_sqflite_plugin:` line from DBScope's pubspec.yaml
// 3. remove the import + `register(SqfliteRemotePlugin())` call from
// `lib/main.dart`
// 4. delete any saved profiles of this kind from the connection picker.

export 'src/plugin.dart'
    show SqfliteRemotePlugin, SqfliteRemoteKindPlugin, kSqfliteRemoteKind;
