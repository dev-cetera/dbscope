// jsonSourceOf is the bridge between `package:postgres`'s decoded
// jsonb values (live Map/List/String/etc.) and the JSON editor dialog
// (which expects valid JSON source text). The contracts:
// * Maps and Lists encode to JSON, not Dart `toString()` syntax —
// so the editor opens with `{"a":1}`, not `{a: 1}`.
// * A jsonb `"hello"` value, which the driver decodes to the Dart
// String `hello`, re-quotes to `"hello"` so the editor sees valid
// JSON.
// * A `text` column storing valid JSON source passes through
// untouched — we don't double-encode.

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/grid/json_dialogs.dart';

void main() {
  group('jsonSourceOf', () {
    test('null → empty string', () {
      expect(jsonSourceOf(null), '');
    });

    test('Map → JSON object source', () {
      expect(jsonSourceOf({'a': 1, 'b': 'x'}), '{"a":1,"b":"x"}');
    });

    test('List → JSON array source', () {
      expect(jsonSourceOf([1, 'two', true]), '[1,"two",true]');
    });

    test('bare Dart String → quoted JSON string source', () {
      expect(jsonSourceOf('hello'), '"hello"');
    });

    test('numbers and bools encode as JSON literals', () {
      expect(jsonSourceOf(42), '42');
      expect(jsonSourceOf(3.14), '3.14');
      expect(jsonSourceOf(true), 'true');
    });

    test('String that is already valid JSON source passes through', () {
      // A text column holding JSON source, or a roundtripped value.
      expect(jsonSourceOf('{"a":1}'), '{"a":1}');
      expect(jsonSourceOf('"already-quoted"'), '"already-quoted"');
      expect(jsonSourceOf('[1,2,3]'), '[1,2,3]');
    });
  });
}
