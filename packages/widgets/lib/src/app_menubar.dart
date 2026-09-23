import 'package:flutter/material.dart';

import 'palette.dart';

class AppMenuItem {
  const AppMenuItem({
    required this.label,
    this.onPressed,
    this.checked = false,
    this.divider = false,
    this.shortcut,
  });
  const AppMenuItem.divider()
    : label = '',
      onPressed = null,
      checked = false,
      divider = true,
      shortcut = null;

  final String label;
  final VoidCallback? onPressed;
  final bool checked;
  final bool divider;
  final String? shortcut;
}

class AppMenu {
  const AppMenu({required this.label, required this.items});
  final String label;
  final List<AppMenuItem> items;
}

/// Top-of-window menu strip. Same structure in both modes; the only chrome
/// difference is the rounded popup under flat mode.
class AppMenuBar extends StatefulWidget {
  const AppMenuBar({super.key, required this.menus});
  final List<AppMenu> menus;

  @override
  State<AppMenuBar> createState() => _AppMenuBarState();
}

class _AppMenuBarState extends State<AppMenuBar> {
  int? _open;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border:
            p.isBevel
                ? null
                : Border(bottom: BorderSide(color: p.border, width: 1)),
      ),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          for (var i = 0; i < widget.menus.length; i++)
            _menuButton(i, widget.menus[i]),
        ],
      ),
    );
  }

  Widget _menuButton(int idx, AppMenu m) {
    final p = AppPalette.of(context);
    final active = _open == idx;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _show(idx, d.globalPosition, m),
        child: Container(
          decoration: BoxDecoration(color: active ? p.accent : null),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            m.label,
            style: TextStyle(
              fontSize: p.bodyFontSize,
              fontFamily: p.uiFontFamily,
              color: active ? p.onAccent : p.text,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _show(int idx, Offset where, AppMenu m) async {
    final p = AppPalette.of(context);
    setState(() => _open = idx);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final radius = BorderRadius.circular(p.cornerRadius);
    final selected = await showMenu<int>(
      context: context,
      color: p.surface,
      elevation: p.isBevel ? 0 : 4,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: p.border),
        borderRadius: radius,
      ),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(where.dx, where.dy + 18, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (var i = 0; i < m.items.length; i++)
          if (m.items[i].divider)
            const PopupMenuDivider(height: 4)
          else
            PopupMenuItem<int>(
              value: i,
              enabled: m.items[i].onPressed != null,
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    child:
                        m.items[i].checked
                            ? Icon(Icons.check, size: 12, color: p.text)
                            : null,
                  ),
                  Expanded(
                    child: Text(
                      m.items[i].label,
                      style: TextStyle(
                        fontSize: p.bodyFontSize,
                        fontFamily: p.uiFontFamily,
                        color: p.text,
                      ),
                    ),
                  ),
                  if (m.items[i].shortcut != null) ...[
                    const SizedBox(width: 16),
                    Text(
                      m.items[i].shortcut!,
                      style: TextStyle(
                        fontSize: p.bodyFontSize,
                        fontFamily: p.uiFontFamily,
                        color: p.mutedText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
      ],
    );
    if (!mounted) return;
    setState(() => _open = null);
    if (selected != null) m.items[selected].onPressed?.call();
  }
}
