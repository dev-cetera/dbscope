// Renders the small Markdown that schema descriptions use into ONE
// InlineSpan, so the same text works in a Tooltip's `richMessage` and in a
// `SelectableText.rich` (neither takes arbitrary widgets).
//
// Supported: paragraphs, headings, **bold**, *italic*, ~~strike~~,
// `code`, fenced code, nested lists, block quotes, links (shown, not
// tappable) and horizontal rules. Everything after a rule renders as muted
// fine print: descriptions lead with plain English and put the technical
// detail below a rule.

import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:widgets/widgets.dart';

class MarkdownColors {
  final Color text;
  final Color muted;
  final Color strong;
  final Color code;
  final Color codeBackground;
  final Color link;
  final String monoFontFamily;

  const MarkdownColors({
    required this.text,
    required this.muted,
    required this.strong,
    required this.code,
    required this.codeBackground,
    required this.link,
    required this.monoFontFamily,
  });

  factory MarkdownColors.of(AppPalette palette) => MarkdownColors(
    text: palette.text,
    muted: palette.mutedText,
    strong: palette.accent,
    code: palette.typeString,
    codeBackground: palette.surfaceRecessed,
    link: palette.accent,
    monoFontFamily: palette.monoFontFamily,
  );
}

/// [source] as one span. [base] is the body style (font, size, colour).
TextSpan markdownSpan(
  String source, {
  required TextStyle base,
  required MarkdownColors colors,
}) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parse(source.trim());
  final builder = _SpanBuilder(base: base, colors: colors);
  for (final node in nodes) {
    builder.block(node);
  }
  return TextSpan(style: base, children: builder.spans);
}

const _kRuleLength = 28;
const _kFinePrintScale = 0.92;

class _SpanBuilder {
  final TextStyle base;
  final MarkdownColors colors;
  final List<InlineSpan> spans = [];

  /// True after a horizontal rule: the rest is fine print.
  bool _finePrint = false;

  _SpanBuilder({required this.base, required this.colors});

  TextStyle get _body => _finePrint
      ? base.copyWith(
          color: colors.muted,
          fontSize: (base.fontSize ?? 12.0) * _kFinePrintScale,
        )
      : base.copyWith(color: colors.text);

  /// Blank line between blocks; nothing before the first.
  void _paragraphBreak() {
    if (spans.isNotEmpty) spans.add(const TextSpan(text: '\n\n'));
  }

  void _lineBreak() {
    if (spans.isNotEmpty) spans.add(const TextSpan(text: '\n'));
  }

  void block(md.Node node) {
    if (node is md.Text) {
      _paragraphBreak();
      spans.add(TextSpan(text: node.text, style: _body));
      return;
    }
    if (node is! md.Element) return;
    switch (node.tag) {
      case 'hr':
        _finePrint = true;
        _paragraphBreak();
        spans.add(
          TextSpan(
            text: '─' * _kRuleLength,
            style: base.copyWith(color: colors.muted),
          ),
        );
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        _paragraphBreak();
        _inlineChildren(
          node,
          _body.copyWith(fontWeight: FontWeight.w700, color: colors.strong),
        );
      case 'ul' || 'ol':
        _paragraphBreak();
        _list(node, indent: '');
      case 'blockquote':
        _paragraphBreak();
        spans.add(
          TextSpan(
            text: '▍ ',
            style: _body.copyWith(color: colors.muted),
          ),
        );
        _inlineFlattened(
          node,
          _body.copyWith(fontStyle: FontStyle.italic, color: colors.muted),
        );
      case 'pre':
        _paragraphBreak();
        spans.add(
          TextSpan(
            text: node.textContent.trimRight(),
            style: _code(_body),
          ),
        );
      default:
        // 'p', 'table' and anything unexpected: its text, inline.
        _paragraphBreak();
        _inlineChildren(node, _body);
    }
  }

  void _list(md.Element list, {required String indent}) {
    var number = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    var first = true;
    for (final item in list.children ?? const <md.Node>[]) {
      if (item is! md.Element || item.tag != 'li') continue;
      if (!first) _lineBreak();
      first = false;
      final marker = list.tag == 'ol' ? '${number++}. ' : '• ';
      spans.add(
        TextSpan(
          text: '$indent$marker',
          style: _body.copyWith(color: colors.strong),
        ),
      );
      for (final child in item.children ?? const <md.Node>[]) {
        if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
          _lineBreak();
          _list(child, indent: '$indent    ');
        } else if (child is md.Element && child.tag == 'p') {
          _inlineChildren(child, _body);
        } else {
          _inline(child, _body);
        }
      }
    }
  }

  /// Every block inside [node] as one run of inline text (block quotes).
  void _inlineFlattened(md.Element node, TextStyle style) {
    var first = true;
    for (final child in node.children ?? const <md.Node>[]) {
      if (!first) spans.add(TextSpan(text: ' ', style: style));
      first = false;
      if (child is md.Element) {
        _inlineChildren(child, style);
      } else {
        _inline(child, style);
      }
    }
  }

  void _inlineChildren(md.Element node, TextStyle style) {
    for (final child in node.children ?? const <md.Node>[]) {
      _inline(child, style);
    }
  }

  TextStyle _code(TextStyle style) => style.copyWith(
    fontFamily: colors.monoFontFamily,
    color: colors.code,
    backgroundColor: colors.codeBackground,
  );

  void _inline(md.Node node, TextStyle style) {
    if (node is md.Text) {
      spans.add(TextSpan(text: node.text, style: style));
      return;
    }
    if (node is! md.Element) return;
    switch (node.tag) {
      case 'strong':
        _inlineChildren(
          node,
          style.copyWith(
            fontWeight: FontWeight.w700,
            color: _finePrint ? null : colors.strong,
          ),
        );
      case 'em':
        _inlineChildren(node, style.copyWith(fontStyle: FontStyle.italic));
      case 'del':
        _inlineChildren(
          node,
          style.copyWith(decoration: TextDecoration.lineThrough),
        );
      case 'code':
        spans.add(TextSpan(text: node.textContent, style: _code(style)));
      case 'a':
        _inlineChildren(
          node,
          style.copyWith(
            color: colors.link,
            decoration: TextDecoration.underline,
          ),
        );
      case 'br':
        spans.add(const TextSpan(text: '\n'));
      case 'img':
        spans.add(TextSpan(text: node.attributes['alt'] ?? '', style: style));
      default:
        _inlineChildren(node, style);
    }
  }
}
