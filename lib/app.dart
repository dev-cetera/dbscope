import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:key_flow/key_flow.dart';
import 'package:widgets/widgets.dart';

import 'connection/registry.dart';
import 'rpc/backend_client.dart';
import 'rpc/scope.dart';
import 'shell/app_commands.dart';
import 'shell/app_key_flow.dart';
import 'shell/app_state.dart';
import 'shell/command_registry.dart';
import 'shell/footer.dart';
import 'shell/shell_listenable.dart';
import 'shell/sidebar.dart';
import 'shell/tab_strip.dart';
import 'shell/theme_registry.dart';
import 'tabs/tab_kind.dart';
import 'update/update_prompt.dart';

class DBScopeApp extends StatefulWidget {
  const DBScopeApp({
    super.key,
    required this.backend,
    this.windowId = 0,
    this.launchPayload = '',
    this.showWelcome = false,
  });
  final BackendClient backend;
  final int windowId;
  final String launchPayload;

  /// Open the welcome dialog once the first frame is up. `main.dart`
  /// decides this for the host window with `shouldShowWelcome`.
  final bool showWelcome;

  @override
  State<DBScopeApp> createState() => _DBScopeAppState();
}

class _DBScopeAppState extends State<DBScopeApp> {
  // The root reads AppState only for the theme, so it rebuilds only when
  // the theme changes — not on every notify (a drag fires one per pointer
  // event). That also builds each ThemeData once per switch: the builders
  // return a fresh ThemeData that never compares equal to the last
  // (component themes hold fresh `resolveWith` closures), and handing
  // MaterialApp a new one restarts AnimatedTheme's 200 ms lerp, which
  // rebuilds every Theme.of dependant on each frame.
  ThemePlugin? _themePlugin;
  late ThemeData _theme;

  void _adoptTheme() {
    _themePlugin = AppState.instance.themePlugin;
    _theme = _themePlugin?.build() ?? ThemeData.fallback();
  }

  void _onAppStateChange() {
    if (identical(AppState.instance.themePlugin, _themePlugin)) return;
    setState(_adoptTheme);
  }

  @override
  void initState() {
    super.initState();
    // May switch theme synchronously; adopt after it, and listen only
    // once initState can no longer be interrupted by a setState.
    unawaited(_applyLaunchPayload());
    _adoptTheme();
    AppState.instance.addListener(_onAppStateChange);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onAppStateChange);
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    // Hot reload: pick up edits to the theme builders.
    _adoptTheme();
  }

  Future<void> _applyLaunchPayload() async {
    final payload = widget.launchPayload.trim();
    if (payload.isEmpty) return;
    try {
      final json = jsonDecode(payload);
      if (json is Map<String, Object?>) {
        // Apply theme immediately so the first frame paints in the
        // parent window's theme, not the AppState default.
        final themeId = json['themeId'] as String?;
        if (themeId != null) AppState.instance.setThemeId(themeId);
        final profileId = json['profileId'] as String?;
        if (profileId != null) {
          // Defer until registry has loaded its profile list.
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            await ConnectionRegistry.instance.setActive(profileId);
          });
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return BackendScope(
      client: widget.backend,
      // Theme + its overlays both come from the registry — Doom's mugshot
      // only ships when the Doom plugin is registered, etc.
      child: MaterialApp(
        title: widget.windowId == 0 ? 'DBScope' : 'DBScope — window ${widget.windowId}',
        debugShowCheckedModeBanner: false,
        theme: _theme,
        darkTheme: _theme,
        themeMode: _theme.brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        navigatorKey: appNavigatorKey,
        home: widget.showWelcome ? const _WelcomeOnStartup(child: _Shell()) : const _Shell(),
        builder: (context, child) {
          return AppKeyFlow(
            child: Stack(
              children: [
                ?child,
                for (final builder in _themePlugin?.overlays ?? const <WidgetBuilder>[])
                  builder(context),
                // Only the host window checks for updates (main.dart starts it).
                if (widget.windowId == 0) const UpdatePrompt(),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Opens the welcome dialog over [child] after the first frame, once.
/// It sits under `MaterialApp.home` because the dialog needs a Navigator.
class _WelcomeOnStartup extends StatefulWidget {
  const _WelcomeOnStartup({required this.child});
  final Widget child;

  @override
  State<_WelcomeOnStartup> createState() => _WelcomeOnStartupState();
}

class _WelcomeOnStartupState extends State<_WelcomeOnStartup> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(showWelcome(context));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) {
    // Shortcuts and menus come from AppKeyFlow (shell/app_commands.dart).
    return AnimatedBuilder(
      animation: shellListenable,
      builder: (context, _) {
        return Focus(
          autofocus: true,
          child: Scaffold(
            body: Column(
              children: [
                const TabStrip(),
                Expanded(child: _Body()),
                const Footer(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Stable identity for the main area, so showing / hiding / moving the
/// sidebar RE-PARENTS the active tab's subtree instead of rebuilding it.
///
/// The obvious shape — `if (!visible) return mainArea;` plus a `Row` in
/// the other branch — changes the widget type sitting in this slot, and
/// `Widget.canUpdate` then returns false, so Flutter unmounts the whole
/// tab subtree and inflates a fresh one. Every `State` below dies with
/// it, which is how a sidebar toggle silently reset the Schema canvas's
/// one-shot auto-fit latch and re-centred the whole diagram, and how the
/// Linked canvas lost its per-node auto-width bookkeeping.
final GlobalKey<State<StatefulWidget>> _mainAreaKey = GlobalKey();

class _Body extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    // Built fresh on every rebuild rather than hoisted into a const
    // widget: it reads sidebarWidth / sidebarOnRight off the singleton,
    // and Flutter skips updating a child whose widget is identical to
    // the previous one — a const sidebar would stop tracking drags.
    final sidebar = Resizable(
      width: state.sidebarWidth,
      minWidth: 180.0,
      maxWidth: 520.0,
      side: state.sidebarOnRight ? ResizeSide.left : ResizeSide.right,
      onResized: state.setSidebarWidth,
      // A named area: F6 moves between it and the open tab.
      child: const KeyFlowScope(region: 'Sidebar', child: Sidebar()),
    );
    return Row(
      children: [
        if (state.sidebarVisible && !state.sidebarOnRight) sidebar,
        Expanded(
          child: KeyedSubtree(
            key: _mainAreaKey,
            child: KeyFlowScope(
              region: 'Tab',
              child: _MainArea(active: state.active),
            ),
          ),
        ),
        if (state.sidebarVisible && state.sidebarOnRight) sidebar,
      ],
    );
  }
}

class _MainArea extends StatelessWidget {
  const _MainArea({required this.active});
  final TabModel? active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (active == null) {
      return ColoredBox(
        color: theme.colorScheme.surface,
        child: const EmptyState(
          icon: Icons.lan_outlined,
          iconSize: 64.0,
          message: 'Open a table from the sidebar, or press Cmd+T for a new query.',
        ),
      );
    }
    final tab = active!;
    final kind = TabKindRegistry.instance.lookupForTab(tab);
    if (kind == null) return const SizedBox.shrink();
    return kind.buildView(tab);
  }
}
