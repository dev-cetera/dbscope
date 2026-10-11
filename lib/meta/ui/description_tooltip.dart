// The hover card for a schema description (table, column, schema, named
// query): Markdown rendered in colour, capped to a readable width, on the
// theme's raised surface — instead of the platform tooltip's single line
// stretched across the screen.

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import 'markdown_span.dart';

const _kMaxWidth = 440.0;
const _kLineHeight = 1.35;

class DescriptionTooltip extends StatelessWidget {
  /// Markdown. Empty shows no tooltip at all.
  final String markdown;
  final Widget child;
  final Duration waitDuration;

  const DescriptionTooltip({
    super.key,
    required this.markdown,
    required this.child,
    this.waitDuration = const Duration(milliseconds: 500),
  });

  @override
  Widget build(BuildContext context) {
    if (markdown.trim().isEmpty) return child;
    final palette = AppPalette.of(context);
    return Tooltip(
      richMessage: descriptionSpan(context, markdown),
      constraints: const BoxConstraints(maxWidth: _kMaxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        border: Border.all(color: palette.borderStrong),
        borderRadius: BorderRadius.circular(palette.cornerRadius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12.0,
            offset: Offset(0.0, 4.0),
          ),
        ],
      ),
      waitDuration: waitDuration,
      child: child,
    );
  }
}

/// [markdown] in the theme's body style, for tooltips and About dialogs.
TextSpan descriptionSpan(BuildContext context, String markdown) {
  final palette = AppPalette.of(context);
  return markdownSpan(
    markdown,
    base: TextStyle(
      fontFamily: palette.uiFontFamily,
      fontSize: palette.bodyFontSize,
      height: _kLineHeight,
      color: palette.text,
    ),
    colors: MarkdownColors.of(palette),
  );
}
