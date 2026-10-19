import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../connection/registry.dart';
import '../tabs/tab_kind.dart';
import '../util/hover_state_mixin.dart';
import 'app_state.dart';
import 'shell_listenable.dart';

/// Chrome-style horizontal tab strip.
///
/// Rounded top corners, active tab visually merges with the body below
/// (top accent bar + matching background), pin support, hover-only close
/// X on inactive tabs, middle-click to close, drag-to-reorder, and a
/// right-click context menu with Close / Close others / Close to right /
/// Close to left / Pin.
class TabStrip extends StatelessWidget {
  const TabStrip({super.key});

  static const double _height = 36;

  /// Strip background, derived from the body surface so it works for
  /// both palettes. Pure Material 3 surface roles collapse to the same
  /// colour in some palettes (vsCodeDark has surface == surfaceContainerHigh)
  /// so we shift it by alpha-blend instead.
  static Color stripBgFor(AppPalette palette) {
    final isDark = ThemeData.estimateBrightnessForColor(palette.surface) == Brightness.dark;
    return Color.alphaBlend(
      Colors.black.withValues(alpha: isDark ? 0.50 : 0.10),
      palette.surface,
    );
  }

  /// Inserted as `const` under the shell, so a parent rebuild skips it —
  /// it subscribes itself.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: shellListenable,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final state = AppState.instance;
    final registry = ConnectionRegistry.instance;
    final palette = AppPalette.of(context);
    return Container(
      height: _height,
      color: stripBgFor(palette),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: state.tabs.isEmpty
                ? const SizedBox.shrink()
                : ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    proxyDecorator: (child, index, animation) => Material(
                      color: Colors.transparent,
                      child: child,
                    ),
                    // onReorderItem's newIndex already accounts for the
                    // dragged tab's removal, so it's moveTab's target.
                    onReorderItem: state.moveTab,
                    itemCount: state.tabs.length,
                    itemBuilder: (_, i) {
                      final tab = state.tabs[i];
                      return ReorderableDragStartListener(
                        key: ValueKey(tab.id),
                        index: i,
                        child: _Tab(tab: tab, state: state),
                      );
                    },
                  ),
          ),
          _NewTabButton(
            enabled: registry.activeId != null,
            onTap: () => state.newQueryTab(registry.activeId!),
          ),
          const SizedBox(width: 4.0),
        ],
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({required this.tab, required this.state});
  final TabModel tab;
  final AppState state;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with HoverStateMixin {
  IconData _iconFor(TabModel tab) {
    return TabKindRegistry.instance.lookupForTab(tab)?.icon ?? Icons.code;
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final state = widget.state;
    final tab = widget.tab;
    final tabIndex = state.tabs.indexWhere((other) => other.id == tab.id);
    final hasRight = tabIndex >= 0 && state.tabs.skip(tabIndex + 1).any((other) => !other.pinned);
    final hasLeft = tabIndex > 0 && state.tabs.take(tabIndex).any((other) => !other.pinned);
    final hasOthers = state.tabs.any(
      (other) => other.id != tab.id && !other.pinned,
    );

    final selected = await showAppContextMenu<String>(
      context: context,
      globalPosition: globalPosition,
      items: [
        const AppMenuEntry(value: 'close', label: 'Close', icon: Icons.close),
        AppMenuEntry(
          value: 'close_others',
          label: 'Close others',
          enabled: hasOthers,
        ),
        AppMenuEntry(
          value: 'close_right',
          label: 'Close tabs to the right',
          enabled: hasRight,
        ),
        AppMenuEntry(
          value: 'close_left',
          label: 'Close tabs to the left',
          enabled: hasLeft,
        ),
        const AppMenuEntry.divider(),
        AppMenuEntry(
          value: 'pin',
          label: tab.pinned ? 'Unpin tab' : 'Pin tab',
          icon: Icons.push_pin_outlined,
        ),
        const AppMenuEntry.divider(),
        const AppMenuEntry(
          value: 'copy_title',
          label: 'Copy title',
          icon: Icons.copy,
        ),
      ],
    );
    switch (selected) {
      case 'close':
        state.closeTab(tab.id);
      case 'close_others':
        state.closeOtherTabs(tab.id);
      case 'close_right':
        state.closeTabsToRight(tab.id);
      case 'close_left':
        state.closeTabsToLeft(tab.id);
      case 'pin':
        state.togglePin(tab.id);
      case 'copy_title':
        await Clipboard.setData(ClipboardData(text: tab.title));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isActive = widget.state.active?.id == widget.tab.id;
    final isPinned = widget.tab.pinned;
    final showClose = (isActive || isHovered) && !isPinned;

    // Active = body surface so the tab visually merges with the panel
    // below. Inactive = strip background so it blends with the chrome.
    final background = isActive ? palette.surface : TabStrip.stripBgFor(palette);
    final onBgBase = ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black;
    final foreground = isActive ? onBgBase : onBgBase.withValues(alpha: 0.6);
    final accent = palette.accent;

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setHovered(hovered: true),
      onExit: (_) => setHovered(hovered: false),
      child: Listener(
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.mouse &&
              event.buttons == kMiddleMouseButton &&
              !isPinned) {
            widget.state.closeTab(widget.tab.id);
          }
        },
        child: GestureDetector(
          onTap: () => widget.state.selectTab(widget.tab.id),
          onSecondaryTapDown: (details) => _showContextMenu(context, details.globalPosition),
          // Material owns background + textStyle so the per-item Material
          // that ReorderableListView wraps around us can't fall back to the
          // theme's default text colour and wash out the title/X.
          child: Container(
            margin: const EdgeInsets.only(left: 2.0, top: 4.0),
            child: Material(
              color: background,
              textStyle: TextStyle(
                color: foreground,
                fontFamily: palette.uiFontFamily,
                fontSize: palette.bodyFontSize,
              ),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8.0),
                topRight: Radius.circular(8.0),
              ),
              // BoxDecoration's borderRadius rejects non-uniform border
              // colors, so we round via ClipRRect and let the Border draw
              // square sides inside the clip.
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8.0),
                  topRight: Radius.circular(8.0),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: isActive ? accent : Colors.transparent,
                        width: isActive ? 3 : 1,
                      ),
                      left: BorderSide(
                        color: isActive ? palette.borderStrong : Colors.transparent,
                      ),
                      right: BorderSide(
                        color: isActive ? palette.borderStrong : Colors.transparent,
                      ),
                      // Active tab's bottom edge merges with the body surface
                      // so it looks like one continuous panel.
                      bottom: BorderSide(
                        color: isActive ? background : Colors.transparent,
                      ),
                    ),
                  ),
                  child: IconTheme.merge(
                    data: IconThemeData(color: foreground, size: 13.0),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10.0, right: 10.0),
                      child: ConstrainedBox(
                        constraints: isPinned
                            ? const BoxConstraints(
                                maxWidth: 48.0,
                                minWidth: 40.0,
                              )
                            : const BoxConstraints(
                                maxWidth: 240.0,
                                minWidth: 100.0,
                              ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isPinned ? Icons.push_pin : _iconFor(widget.tab),
                              color: isPinned ? accent : foreground,
                            ),
                            if (!isPinned) ...[
                              const SizedBox(width: 6.0),
                              Flexible(
                                child: Text(
                                  widget.tab.title,
                                  style: TextStyle(
                                    color: foreground,
                                    fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                              const SizedBox(width: 6.0),
                              SizedBox(
                                width: 16.0,
                                height: 16.0,
                                child: showClose
                                    ? _CloseDot(
                                        color: foreground,
                                        onTap: () => widget.state.closeTab(
                                          widget.tab.id,
                                        ),
                                      )
                                    : null,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseDot extends StatefulWidget {
  const _CloseDot({required this.color, required this.onTap});
  final Color color;
  final VoidCallback onTap;

  @override
  State<_CloseDot> createState() => _CloseDotState();
}

class _CloseDotState extends State<_CloseDot> with HoverStateMixin {
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setHovered(hovered: true),
      onExit: (_) => setHovered(hovered: false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: isHovered ? widget.color.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(4.0),
          ),
          child: Icon(Icons.close, size: 12.0, color: widget.color),
        ),
      ),
    );
  }
}

class _NewTabButton extends StatefulWidget {
  const _NewTabButton({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_NewTabButton> createState() => _NewTabButtonState();
}

class _NewTabButtonState extends State<_NewTabButton> with HoverStateMixin {
  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Tooltip(
      message: 'New query (Cmd+T)',
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setHovered(hovered: true),
        onExit: (_) => setHovered(hovered: false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 8.0),
            padding: const EdgeInsets.all(2.0),
            decoration: BoxDecoration(
              color: isHovered && widget.enabled
                  ? palette.text.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4.0),
            ),
            child: Icon(
              Icons.add,
              size: 16.0,
              color: widget.enabled ? palette.text : palette.mutedText,
            ),
          ),
        ),
      ),
    );
  }
}
