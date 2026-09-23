import 'package:flutter/material.dart';

import 'chrome.dart';
import 'palette.dart';

/// Push button that adapts to the active chrome:
/// bevel mode: classic Win95 4-layer bevel that sinks on press.
/// flat mode: rounded rect with 1px border, accent tint on press/hover.
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    this.minHeight = 22,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final EdgeInsets padding;
  final double minHeight;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _down = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final enabled = widget.onPressed != null;
    final pressed = _down && enabled;
    final centered = Center(
      widthFactor: 1,
      child: DefaultTextStyle.merge(
        style: TextStyle(
          fontSize: p.bodyFontSize,
          fontFamily: p.uiFontFamily,
          color: p.text,
        ),
        child: widget.child,
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTapUp:
          enabled
              ? (_) {
                setState(() => _down = false);
                widget.onPressed?.call();
              }
              : null,
      child: MouseRegion(
        onEnter: enabled ? (_) => setState(() => _hover = true) : null,
        onExit: enabled ? (_) => setState(() => _hover = false) : null,
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.5,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: widget.minHeight),
            child:
                p.isBevel
                    ? bevelBox(
                      palette: p,
                      sunken: pressed,
                      background: p.surface,
                      padding: widget.padding,
                      child: centered,
                    )
                    : flatBox(
                      palette: p,
                      background:
                          pressed
                              ? p.accentSoft
                              : _hover && enabled
                              ? p.rowHover
                              : p.surfaceRaised,
                      padding: widget.padding,
                      child: centered,
                    ),
          ),
        ),
      ),
    );
  }
}

/// Two-state toggle. Selected = sunken (bevel) or accentSoft fill (flat).
class AppToggleButton extends StatefulWidget {
  const AppToggleButton({
    super.key,
    required this.selected,
    required this.onPressed,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  });

  final bool selected;
  final VoidCallback? onPressed;
  final Widget child;
  final EdgeInsets padding;

  @override
  State<AppToggleButton> createState() => _AppToggleButtonState();
}

class _AppToggleButtonState extends State<AppToggleButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final enabled = widget.onPressed != null;
    final centered = Center(widthFactor: 1, child: widget.child);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onPressed,
      child: MouseRegion(
        onEnter: enabled ? (_) => setState(() => _hover = true) : null,
        onExit: enabled ? (_) => setState(() => _hover = false) : null,
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.5,
          child:
              p.isBevel
                  ? bevelBox(
                    palette: p,
                    sunken: widget.selected,
                    background: p.surface,
                    padding: widget.padding,
                    child: centered,
                  )
                  : flatBox(
                    palette: p,
                    background:
                        widget.selected
                            ? p.accentSoft
                            : _hover && enabled
                            ? p.rowHover
                            : p.surfaceRaised,
                    borderColor: widget.selected ? p.accent : p.border,
                    padding: widget.padding,
                    child: centered,
                  ),
        ),
      ),
    );
  }
}
