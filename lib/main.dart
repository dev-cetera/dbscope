import 'dart:async';
import 'dart:ui' as ui;

// Doom theme wired out — re-enable with the pubspec dep + register line below.
// import 'package:dbscope_doom_plugin/dbscope_doom_plugin.dart';
import 'package:dbscope_portal_plugin/dbscope_portal_plugin.dart';
import 'package:dbscope_vscode_dark_plugin/dbscope_vscode_dark_plugin.dart';
// Warcraft theme wired out — re-enable with the pubspec dep + register line below.
// import 'package:dbscope_warcraft_plugin/dbscope_warcraft_plugin.dart';
import 'package:dbscope_win95_plugin/dbscope_win95_plugin.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:code_field/code_field.dart';

import 'app.dart';
import 'code/code_editor_payload.dart';
import 'code/code_editor_subwindow.dart';
import 'connection/registry.dart';
import 'firebase_options.dart';
import 'plugins/builtin_plugin.dart';
import 'plugins/dbscope_plugin.dart';
import 'plugins/platform_plugins.dart';
import 'rpc/backend_client.dart';
import 'rpc/isolate_transport.dart';
import 'server/host.dart';
import 'shell/app_state.dart';
import 'shell/ui_prefs.dart';
import 'util/shell_env.dart';

// Entrypoint for both the host (first) window and any subwindows spawned
// via desktop_multi_window. desktop_multi_window invokes main again in a
// fresh isolate with args = ["multi_window", <id>, <payload>].
//
// Host mode: constructs the canonical Server and a LocalTransport-backed
// client. Also installs a host-side router so subwindows can talk to it.
//
// Subwindow mode: constructs an IsolateTransport-backed client. No
// Server here; we proxy to the host's.
//
// Web mode: forced single-window (no desktop_multi_window). The web
// build of `platformConnectionPlugins()` returns a reduced backend
// set (no Postgres-direct, no local SQLite).
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase is wired for the web build only. firebase_options.dart is
  // configured for `web` (project dbscope-prod); desktop targets throw
  // UnsupportedError from DefaultFirebaseOptions, so the init is gated on
  // kIsWeb and the desktop isolates are left completely untouched.
  if (kIsWeb) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  _registerPlugins();
  // Load syntax-highlighting grammars from package assets. Sync after
  // this completes — every CodeViewer / SyntaxHighlightPlugin reads
  // from GrammarRegistry.defaults. Asset loading goes through
  // rootBundle which works in every Flutter engine, including
  // desktop_multi_window subwindows.
  await loadBundledGrammars();

  final isSubwindow =
      !kIsWeb && args.isNotEmpty && args.first == 'multi_window';

  // Code-editor subwindow: detect FIRST, before any plugin-channel work.
  // The subwindow's Flutter engine doesn't auto-register the host's
  // plugins (SharedPreferences, secure storage, etc.), so calling
  // `AppState.loadPersisted()` here would raise a channel-error on
  // macOS/Windows. The code editor doesn't need any of that state —
  // theme, language, and initial text travel in the launch payload.
  if (isSubwindow) {
    final payload = args.length > 2 ? args[2] : '';
    if (CodeEditorLaunchPayload.isCodeEditorPayload(payload)) {
      final windowId = int.tryParse(args.length > 1 ? args[1] : '0') ?? -1;
      runApp(
        CodeEditorSubwindowApp(
          windowId: windowId,
          payload: CodeEditorLaunchPayload.fromJsonString(payload),
        ),
      );
      return;
    }
  }

  // Restore persisted UI preferences (sidebar/inspector sizes, theme,
  // SQL editor height) before the first frame paints so the saved
  // sizes drive initial layout instead of the in-memory defaults.
  // UiPrefs.init swallows channel errors and falls back to defaults,
  // so this is safe even if SharedPreferences isn't bound here.
  await AppState.instance.loadPersisted();

  // Read the user's shell env file (~/.zshenv by default) now that the
  // configured path is known. A GUI-launched app inherits launchd's
  // minimal environment, so this is the only way an `export FOO=bar` in
  // the user's profile reaches `envValue`. Never throws; a missing file
  // just means "process environment only".
  await ShellEnv.instance.load(path: UiPrefs.instance.envFilePath);

  if (isSubwindow) {
    final windowIdRaw = args.length > 1 ? args[1] : '0';
    final payload = args.length > 2 ? args[2] : '';
    final windowId = int.tryParse(windowIdRaw) ?? -1;

    final transport = IsolateTransport(targetWindowId: 0);
    final client = BackendClient(transport);
    ConnectionRegistry.instance.bind(client: client);
    await ConnectionRegistry.instance.load();
    WidgetsBinding.instance.addObserver(_SubwindowQuitHook());
    runApp(
      DBScopeApp(
        backend: client,
        windowId: windowId,
        launchPayload: payload,
      ),
    );
    return;
  }

  // Host window (or, on web, the only window).
  final host = HostBackend.create();
  if (!kIsWeb) {
    // Wire subwindow→host routing. Skipped on web — there are no
    // subwindows and HostWindowRouter would try to install a
    // desktop_multi_window method-channel handler that doesn't exist.
    HostWindowRouter(
      dispatch: (env, fromWindowId, reply) => host.server.dispatch(env, reply),
    );
  }
  ConnectionRegistry.instance.bind(client: host.localClient);
  await ConnectionRegistry.instance.load();
  // Restore the previous session: tabs first (so they're in the bar
  // when the first frame paints), then reopen the last-used connection
  // if it still exists. Sub-windows skip this; only the host owns the
  // persisted session.
  AppState.instance.enableTabPersistence();
  AppState.instance.restorePersistedTabs();
  final lastConnId = UiPrefs.instance.lastConnectionId;
  if (lastConnId != null &&
      ConnectionRegistry.instance.profileById(lastConnId) != null) {
    // Don't await: auto-connect must not block the first frame, and
    // backends that prompt for credentials (e.g. TOTP) need a
    // BuildContext that doesn't exist yet.
    unawaited(ConnectionRegistry.instance.setActive(lastConnId));
  }
  WidgetsBinding.instance.addObserver(_HostQuitHook(host: host));
  runApp(
    DBScopeApp(
      backend: host.localClient,
      windowId: 0,
      launchPayload: '',
    ),
  );
}

class _HostQuitHook extends WidgetsBindingObserver {
  final HostBackend host;
  _HostQuitHook({required this.host});

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    await ConnectionRegistry.instance.disconnectAll();
    await host.dispose();
    return ui.AppExitResponse.exit;
  }
}

// Universal plugin registration — one shape for every contribution.
//
// Every entry here implements [DbscopePlugin]. Its `register(host)`
// wires whatever the plugin contributes (themes, connection kinds, tab
// kinds, menu items, sidebar actions, AI brokers) into the matching
// per-domain registry exposed by [DbscopeHost].
//
// Adding a new plugin = one new line in this list. Removing one =
// delete the line + delete the package's pubspec dependency. Nothing
// in the host references a plugin by name.
//
// Registration order matters for themes (first registered = fallback
// + appears first in the View menu). Order is otherwise free.
void _registerPlugins() {
  final registry = DbscopePluginRegistry.instance;

  // Host built-ins (tab kinds, sidebar actions, AI brokers).
  registry.register(BuiltinPlugin());

  // Theme plugins.
  // Doom theme wired out — re-enable by restoring the import + pubspec dep.
  // registry.register(DoomPlugin());
  registry.register(Win95ThemePlugin());
  registry.register(VsCodeDarkThemePlugin());
  // Warcraft theme wired out — re-enable by restoring the import + pubspec dep.
  // registry.register(WarcraftThemePlugin());
  registry.register(PortalThemePlugin());

  // Platform-conditional connection-kind plugins.
  for (final plugin in platformConnectionPlugins()) {
    registry.register(plugin);
  }
}

class _SubwindowQuitHook extends WidgetsBindingObserver {
  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    await ConnectionRegistry.instance.disconnectAll();
    return ui.AppExitResponse.exit;
  }
}
