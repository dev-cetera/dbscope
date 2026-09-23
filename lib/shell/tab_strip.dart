import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../connection/registry.dart';
import '../tabs/tab_kind.dart';
import '../util/hover_state_mixin.dart';
import 'app_state.dart';

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
    final isDark =
        ThemeData.estimateBrightnessForColor(palette.surface) ==
        Brightness.dark;
    return Color.alphaBlend(
      Colors.black.withValues(alpha: isDark ? 0.50 : 0.10),
      palette.surface,
    );
  }

  @override
  Widget build(BuildContext context) {
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
                    onReorder: (oldIdx, newIdx) {
                      if (newIdx > oldIdx) newIdx -= 1;
                      state.moveTab(oldIdx, newIdx);
                    },
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
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  final TabModel tab;
  final AppState state;
  const _Tab({required this.tab, required this.state});

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with HoverStateMixin {
  IconData _iconFor(TabModel t) {
    return TabKindRegistry.instance.lookupForTab(t)?.icon ?? Icons.code;
  }

  Future<void> _showContextMenu(BuildContext context, Offset globalPos) async {
    final state = widget.state;
    final tab = widget.tab;
    final tabIdx = state.tabs.indexWhere((t) => t.id == tab.id);
    final hasRight =
        tabIdx >= 0 && state.tabs.skip(tabIdx + 1).any((t) => !t.pinned);
    final hasLeft = tabIdx > 0 && state.tabs.take(tabIdx).any((t) => !t.pinned);
    final hasOthers = state.tabs.any((t) => t.id != tab.id && !t.pinned);

    final selected = await showAppContextMenu<String>(
      context: context,
      globalPosition: globalPos,
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
    final bg = isActive ? palette.surface : TabStrip.stripBgFor(palette);
    final onBgBase = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : Colors.black;
    final fg = isActive ? onBgBase : onBgBase.withValues(alpha: 0.6);
    final accent = palette.accent;

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setHovered(true),
      onExit: (_) => setHovered(false),
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
          onSecondaryTapDown: (d) =>
              _showContextMenu(context, d.globalPosition),
          // Material owns bg + textStyle so the per-item Material that
          // ReorderableListView wraps around us can't fall back to the
          // theme's default text colour and wash out the title/X.
          child: Container(
            margin: const EdgeInsets.only(left: 2, top: 4),
            child: Material(
              color: bg,
              textStyle: TextStyle(
                color: fg,
                fontFamily: palette.uiFontFamily,
                fontSize: palette.bodyFontSize,
              ),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
              // BoxDecoration's borderRadius rejects non-uniform border
              // colors, so we round via ClipRRect and let the Border draw
              // square sides inside the clip.
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: isActive ? accent : Colors.transparent,
                        width: isActive ? 3 : 1,
                      ),
                      left: BorderSide(
                        color: isActive
                            ? palette.borderStrong
                            : Colors.transparent,
                      ),
                      right: BorderSide(
                        color: isActive
                            ? palette.borderStrong
                            : Colors.transparent,
                      ),
                      // Active tab's bottom edge merges with the body surface
                      // so it looks like one continuous panel.
                      bottom: BorderSide(
                        color: isActive ? bg : Colors.transparent,
                      ),
                    ),
                  ),
                  child: IconTheme.merge(
                    data: IconThemeData(color: fg, size: 13),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10, right: 10),
                      child: ConstrainedBox(
                        constraints: isPinned
                            ? const BoxConstraints(maxWidth: 48, minWidth: 40)
                            : const BoxConstraints(
                                maxWidth: 240,
                                minWidth: 100,
                              ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              isPinned ? Icons.push_pin : _iconFor(widget.tab),
                              color: isPinned ? accent : fg,
                            ),
                            if (!isPinned) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  widget.tab.title,
                                  style: TextStyle(
                                    color: fg,
                                    fontWeight: isActive
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: showClose
                                    ? _CloseDot(
                                        color: fg,
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
  final Color color;
  final VoidCallback onTap;
  const _CloseDot({required this.color, required this.onTap});

  @override
  State<_CloseDot> createState() => _CloseDotState();
}

class _CloseDotState extends State<_CloseDot> with HoverStateMixin {
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setHovered(true),
      onExit: (_) => setHovered(false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: isHovered
                ? widget.color.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(Icons.close, size: 12, color: widget.color),
        ),
      ),
    );
  }
}

class _NewTabButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _NewTabButton({required this.enabled, required this.onTap});

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
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setHovered(true),
        onExit: (_) => setHovered(false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: isHovered && widget.enabled
                  ? palette.text.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Icons.add,
              size: 16,
              color: widget.enabled ? palette.text : palette.mutedText,
            ),
          ),
        ),
      ),
    );
  }
}
