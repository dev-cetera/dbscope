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
    this.padding = const EdgeInsets.all(4.0),
  });

  final Widget child;
  final String? title;
  final List<Widget> actions;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) _titleBar(palette, title!),
        Padding(padding: padding, child: child),
      ],
    );
    return palette.isBevel
        ? bevelBox(
          palette: palette,
          sunken: false,
          background: palette.surface,
          child: body,
        )
        : flatBox(palette: palette, background: palette.surface, child: body);
  }

  Widget _titleBar(AppPalette palette, String text) {
    return Container(
      height: 18.0,
      color: palette.isBevel ? palette.accent : palette.surfaceRaised,
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: palette.isBevel ? palette.onAccent : palette.text,
                fontSize: palette.bodyFontSize,
                fontFamily: palette.uiFontFamily,
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
    this.padding = const EdgeInsets.all(2.0),
    this.background,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final fill = background ?? palette.field;
    return palette.isBevel
        ? bevelBox(
          palette: palette,
          sunken: true,
          background: fill,
          padding: padding,
          child: child,
        )
        : flatBox(
          palette: palette,
          background: fill,
          padding: padding,
          child: child,
        );
  }
}
