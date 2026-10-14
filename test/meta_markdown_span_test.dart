// Contract: schema descriptions render from Markdown into one TextSpan.
//
// - **bold** takes the strong colour, `code` the code colour and mono font.
// - Everything after a horizontal rule is muted fine print (descriptions
//   lead with plain English and put developer detail below a rule).
// - Lists render one item per line with a marker.

import 'package:dbscope/meta/ui/markdown_span.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = MarkdownColors(
  text: Color(0xFF000001),
  muted: Color(0xFF000002),
  strong: Color(0xFF000003),
  code: Color(0xFF000004),
  codeBackground: Color(0xFF000005),
  link: Color(0xFF000006),
  monoFontFamily: 'mono',
);

List<TextSpan> _leaves(String source) {
  final out = <TextSpan>[];
  markdownSpan(
    source,
    base: const TextStyle(fontSize: 12.0),
    colors: _colors,
  ).visitChildren((span) {
    if (span is TextSpan && span.text != null) out.add(span);
    return true;
  });
  return out;
}

TextSpan _find(List<TextSpan> spans, String text) =>
    spans.firstWhere((span) => span.text == text);

void main() {
  test('bold and code take their colours', () {
    final spans = _leaves('**A to-do.** Kind is `NOTE`.');
    expect(_find(spans, 'A to-do.').style!.color, _colors.strong);
    expect(_find(spans, 'A to-do.').style!.fontWeight, FontWeight.w700);
    expect(_find(spans, 'NOTE').style!.color, _colors.code);
    expect(_find(spans, 'NOTE').style!.fontFamily, 'mono');
  });

  test('text below a rule is muted fine print', () {
    final spans = _leaves('Plain words.\n\n---\n\nTechnical detail.');
    expect(_find(spans, 'Plain words.').style!.color, _colors.text);
    final detail = _find(spans, 'Technical detail.');
    expect(detail.style!.color, _colors.muted);
    expect(detail.style!.fontSize, lessThan(12.0));
  });

  test('lists put each item on its own line', () {
    final text = _leaves('- one\n- two').map((span) => span.text).join();
    expect(text, '• one\n• two');
  });
}
