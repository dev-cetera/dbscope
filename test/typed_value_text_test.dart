// trimUrlEnd decides what part of a regex-matched URL is the link. The
// contract:
// * Sentence punctuation after a URL (. , ; : ! ? ') is not part of it.
// * A closing bracket belongs to the URL only when the URL holds its
//   opener, so "(see https://a.com/x)" drops the ")" but a Wikipedia
//   "..._(language)" link keeps it.
// * A trailing "/" or other path characters are never cut.

import 'package:dbscope/grid/typed_value_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('trimUrlEnd', () {
    test('drops sentence punctuation', () {
      for (final end in ['.', ',', ';', ':', '!', '?', "'", '.)', '...']) {
        expect(trimUrlEnd('https://example.com/docs/setup$end'), 'https://example.com/docs/setup', reason: end);
      }
    });

    test('drops a closing bracket with no opener in the URL', () {
      expect(trimUrlEnd('https://a.com/x)'), 'https://a.com/x');
      expect(trimUrlEnd('https://a.com/x]'), 'https://a.com/x');
      expect(trimUrlEnd('https://a.com/x},'), 'https://a.com/x');
    });

    test('keeps a bracket that closes one opened inside the URL', () {
      expect(
        trimUrlEnd('https://en.wikipedia.org/wiki/Dart_(language)'),
        'https://en.wikipedia.org/wiki/Dart_(language)',
      );
      expect(
        trimUrlEnd('https://en.wikipedia.org/wiki/Dart_(language).'),
        'https://en.wikipedia.org/wiki/Dart_(language)',
      );
    });

    test('keeps a trailing slash, query and fragment', () {
      for (final url in ['https://a.com/', 'https://a.com/?q=1', 'https://a.com/#top']) {
        expect(trimUrlEnd(url), url);
      }
    });
  });
}
