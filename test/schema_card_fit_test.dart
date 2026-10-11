// Contract: a SchemaCard fits exactly in schemaNodeHeight(). The Linked
// view positions every card in a box of that height, so the subtitle
// flag it passes must match whether the card really shows a subtitle —
// a card given a subtitle (a metadata row label) inside a box sized
// without one overflows by kSchemaSubtitleHeight.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:schema_viewer/schema_viewer.dart';

SchemaNodeData _node({String? subtitle}) => SchemaNodeData(
  id: 'n',
  schema: 'public',
  tableName: 'items',
  subtitle: subtitle,
  fields: [
    SchemaFieldSpec(name: 'id', typeLabel: 'uuid', pk: true),
    SchemaFieldSpec(name: 'group_id', typeLabel: 'uuid', fk: true),
  ],
);

Future<void> _pumpInBox(
  WidgetTester tester,
  SchemaNodeData node, {
  required bool hasSubtitle,
}) => tester.pumpWidget(
  MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: kSchemaNodeWidth,
        height: schemaNodeHeight(2, hasSubtitle: hasSubtitle),
        child: SchemaCard(node: node),
      ),
    ),
  ),
);

void main() {
  testWidgets('a card with a subtitle fits its subtitled height', (
    tester,
  ) async {
    await _pumpInBox(
      tester,
      _node(subtitle: 'Buy milk (OPEN)'),
      hasSubtitle: true,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card without a subtitle fits the plain height', (
    tester,
  ) async {
    await _pumpInBox(tester, _node(), hasSubtitle: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bug this guards: a subtitle in a plain-height box '
      'overflows', (tester) async {
    await _pumpInBox(
      tester,
      _node(subtitle: 'Buy milk (OPEN)'),
      hasSubtitle: false,
    );
    expect(tester.takeException(), isFlutterError);
  });
}
