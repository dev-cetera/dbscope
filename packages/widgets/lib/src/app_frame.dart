import 'package:flutter/material.dart';

import 'chrome.dart';
import 'palette.dart';

/// Raised panel with an optional title bar.
/// bevel mode: Win95 4-layer raised bevel + accent-colored title strip.
/// flat mode: rounded rect with 1px border + surface title strip.
class AppFrame extends StatelessWidget {
  const AppFrame({
    super.key,
    required this.child,
    this.title,
    this.actions = const [],
    this.padding = const EdgeInsets.all(4),
  });

  final Widget child;
  final String? title;
  final List<Widget> actions;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) _titleBar(p, title!),
        Padding(padding: padding, child: child),
      ],
    );
    return p.isBevel
        ? bevelBox(
          palette: p,
          sunken: false,
          background: p.surface,
          child: body,
        )
        : flatBox(palette: p, background: p.surface, child: body);
  }

  Widget _titleBar(AppPalette p, String text) {
    return Container(
      height: 18,
      color: p.isBevel ? p.accent : p.surfaceRaised,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: p.isBevel ? p.onAccent : p.text,
                fontSize: p.bodyFontSize,
                fontFamily: p.uiFontFamily,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Sunken inset panel (text wells, scroll regions). Defaults the background
/// to `palette.field` so it reads as an input surface under either theme.
class AppInset extends StatelessWidget {
  const AppInset({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(2),
    this.background,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final bg = background ?? p.field;
    return p.isBevel
        ? bevelBox(
          palette: p,
          sunken: true,
          background: bg,
          padding: padding,
          child: child,
        )
        : flatBox(palette: p, background: bg, padding: padding, child: child);
  }
}
