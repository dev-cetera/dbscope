import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart' hide AppMenuBar;

import 'connection/registry.dart';
import 'rpc/backend_client.dart';
import 'rpc/scope.dart';
import 'shell/app_state.dart';
import 'shell/footer.dart';
import 'shell/menu_bar.dart';
import 'shell/sidebar.dart';
import 'shell/tab_strip.dart';
import 'tabs/tab_kind.dart';

class DBScopeApp extends StatefulWidget {
  final BackendClient backend;
  final int windowId;
  final String launchPayload;
  const DBScopeApp({
    super.key,
    required this.backend,
    this.windowId = 0,
    this.launchPayload = '',
  });

  @override
  State<DBScopeApp> createState() => _DBScopeAppState();
}

class _DBScopeAppState extends State<DBScopeApp> {
  @override
  void initState() {
    super.initState();
    _applyLaunchPayload();
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
      child: AnimatedBuilder(
        animation: AppState.instance,
        builder: (context, _) {
          // Theme + its overlays both come from the registry — Doom's
          // mugshot only ships when the Doom plugin is registered, etc.
          final active = AppState.instance.themePlugin;
          final theme = active?.build() ?? ThemeData.fallback();
          final overlays = active?.overlays ?? const <WidgetBuilder>[];
          return MaterialApp(
            title: widget.windowId == 0
                ? 'DBScope'
                : 'DBScope — window ${widget.windowId}',
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: theme,
            themeMode: theme.brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            home: const _Shell(),
            builder: (context, child) {
              return Stack(
                children: [
                  ?child,
                  for (final builder in overlays) builder(context),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) {
    final listenable = Listenable.merge([
      AppState.instance,
      ConnectionRegistry.instance,
    ]);
    return AppMenuBar(
      child: AnimatedBuilder(
        animation: listenable,
        builder: (context, _) {
          return CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              // Toggle the sidebar's visibility entirely (Cmd/Ctrl+B).
              const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
                  AppState.instance.toggleSidebarVisible,
              const SingleActivator(LogicalKeyboardKey.keyB, control: true):
                  AppState.instance.toggleSidebarVisible,
              // Focus the sidebar's table filter (Cmd/Ctrl+F). If the
              // sidebar is hidden we show it first so the field becomes
              // reachable.
              const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
                if (!AppState.instance.sidebarVisible) {
                  AppState.instance.toggleSidebarVisible();
                }
                SidebarFocusController.instance.requestFilterFocus();
              },
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ): () {
                if (!AppState.instance.sidebarVisible) {
                  AppState.instance.toggleSidebarVisible();
                }
                SidebarFocusController.instance.requestFilterFocus();
              },
            },
            child: Focus(
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
            ),
          );
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final mainArea = _MainArea(active: state.active);
    if (!state.sidebarVisible) return mainArea;
    final sidebar = Resizable(
      width: state.sidebarWidth,
      minWidth: 180,
      maxWidth: 520,
      side: state.sidebarOnRight ? ResizeSide.left : ResizeSide.right,
      onResized: state.setSidebarWidth,
      child: const Sidebar(),
    );
    if (state.sidebarOnRight) {
      return Row(
        children: [
          Expanded(child: mainArea),
          sidebar,
        ],
      );
    }
    return Row(
      children: [
        sidebar,
        Expanded(child: mainArea),
      ],
    );
  }
}

class _MainArea extends StatelessWidget {
  final TabModel? active;
  const _MainArea({required this.active});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (active == null) {
      return Container(
        color: theme.colorScheme.surface,
        child: const EmptyState(
          icon: Icons.lan_outlined,
          iconSize: 64,
          message:
              'Open a table from the sidebar, or press Cmd+T for a new query.',
        ),
      );
    }
    final tab = active!;
    final kind = TabKindRegistry.instance.lookupForTab(tab);
    if (kind == null) return const SizedBox.shrink();
    return kind.buildView(tab);
  }
}
