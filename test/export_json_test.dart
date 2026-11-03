// Contract: encodeRowsAsJson (the JSON result export) never fails on a
// value the database driver returns, and never drops a column.
// * DateTime is written as a UTC ISO-8601 string, other non-JSON values
//   (BigInt, driver objects) as their text. Bytes stay an array of ints.
// * Repeated column names get suffixes instead of overwriting each other.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dbscope/grid/export_json.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('writes timestamps and big integers instead of failing', () {
    final json = encodeRowsAsJson(
      ['at', 'raw', 'big', 'doc'],
      [
        [DateTime.utc(2026, 1, 2, 3, 4, 5), Uint8List.fromList([1, 2, 3]), BigInt.parse('123456789012345678901234567890'), {'a': 1}],
      ],
    );
    expect(jsonDecode(json), [
      {'at': '2026-01-02T03:04:05.000Z', 'raw': [1, 2, 3], 'big': '123456789012345678901234567890', 'doc': {'a': 1}},
    ]);
  });

  test('keeps every column when two share a name', () {
    final json = encodeRowsAsJson(['id', 'id'], [
      [1, 2],
    ]);
    expect(jsonDecode(json), [
      {'id': 1, 'id_2': 2},
    ]);
  });
}
