// Contract: schema diagram cards never sit on top of each other.
//
// - `layoutSchemaNodes` places every card at least kSchemaNodeMargin
//   from every other card, in both layout modes and in the no-edge grid.
// - `cascadeSeparate` (run when a card is dragged, expanded or resized)
//   leaves no two cards closer than kSchemaNodeMargin unless both are
//   pinned. That holds for a push chain longer than any fixed pass count
//   and when a pushed card would land on a pinned one.
// - Pinned cards (`movedIds`) never move.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:schema_viewer/schema_viewer.dart';

SchemaNodeData _node(String id, {int fields = 2}) => SchemaNodeData(
  id: id,
  schema: 'public',
  tableName: id,
  compact: false,
  fields: [
    for (var i = 0; i < fields; i++) SchemaFieldSpec(name: 'c$i', typeLabel: 'int', pk: i == 0),
  ],
);

/// Every pair of cards closer than [kSchemaNodeMargin], as "a/b" labels.
List<String> _crowdedPairs(
  Map<String, Offset> positions,
  ({double w, double h}) Function(String id) dims, {
  Set<String> ignorePairsWithin = const {},
}) {
  final ids = positions.keys.toList();
  final out = <String>[];
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      final a = ids[i];
      final b = ids[j];
      if (ignorePairsWithin.contains(a) && ignorePairsWithin.contains(b)) continue;
      final da = dims(a);
      final db = dims(b);
      final ra = Rect.fromLTWH(positions[a]!.dx, positions[a]!.dy, da.w, da.h);
      final rb = Rect.fromLTWH(positions[b]!.dx, positions[b]!.dy, db.w, db.h);
      // Allow a hair of float error under the margin.
      if (ra
          .inflate(kSchemaNodeMargin / 2 - 0.01)
          .overlaps(rb.inflate(kSchemaNodeMargin / 2 - 0.01))) {
        out.add('$a/$b');
      }
    }
  }
  return out;
}

void main() {
  group('layoutSchemaNodes', () {
    List<SchemaNodeData> nodes() => [
      for (var i = 0; i < 12; i++) _node('t$i', fields: 1 + i % 5),
    ];
    // A hub with many children plus a cycle, so ranks hold many cards.
    final edges = [
      for (var i = 1; i < 12; i++) SchemaEdgeData(id: 'e$i', sourceId: 't0', targetId: 't$i'),
      const SchemaEdgeData(id: 'c1', sourceId: 't3', targetId: 't4'),
      const SchemaEdgeData(id: 'c2', sourceId: 't4', targetId: 't3'),
    ];

    for (final mode in SchemaLayoutMode.values) {
      test('keeps every card apart in ${mode.name} mode', () {
        final list = nodes();
        layoutSchemaNodes(list, edges, mode: mode);
        final byId = {for (final node in list) node.id: node};
        expect(
          _crowdedPairs(
            {for (final node in list) node.id: node.position},
            (id) => (w: effectiveNodeWidth(byId[id]!), h: renderedNodeHeight(byId[id]!)),
          ),
          isEmpty,
        );
      });
    }

    test('keeps every card apart with no relationships', () {
      final list = nodes();
      layoutSchemaNodes(list, const []);
      final byId = {for (final node in list) node.id: node};
      expect(
        _crowdedPairs(
          {for (final node in list) node.id: node.position},
          (id) => (w: effectiveNodeWidth(byId[id]!), h: renderedNodeHeight(byId[id]!)),
        ),
        isEmpty,
      );
    });
  });

  group('cascadeSeparate', () {
    const w = 200.0;
    const h = 100.0;
    ({double w, double h}) dims(String _) => (w: w, h: h);

    test('separates a column longer than eight cards when the top one grows', () {
      // A tidy 20-card column whose top card is expanded to five times
      // its height: the push has to travel the whole chain.
      final positions = <String, Offset>{
        for (var i = 0; i < 20; i++) 'n$i': Offset(0, i * (h + kSchemaNodeMargin)),
      };
      ({double w, double h}) grownDims(String id) => (w: w, h: id == 'n0' ? h * 5 : h);
      cascadeSeparate(
        movedIds: {'n0'},
        positions: positions,
        dimsFor: grownDims,
        allIds: positions.keys,
      );
      expect(_crowdedPairs(positions, grownDims), isEmpty);
    });

    test('never leaves a card on top of another in a crowded canvas', () {
      // A tidy grid, then one card is dropped somewhere at random (a
      // drag). A pushed card has to be checked against the dropped card
      // too, or a chain of pushes can land it back on top of it.
      final random = math.Random(7);
      for (var trial = 0; trial < 1000; trial++) {
        final positions = <String, Offset>{
          for (var i = 0; i < 12; i++)
            'n$i': Offset((i % 4) * (w + kSchemaNodeMargin), (i ~/ 4) * (h + kSchemaNodeMargin)),
        };
        final pinned = 'n${random.nextInt(12)}';
        final before = Offset(random.nextDouble() * 800, random.nextDouble() * 350);
        positions[pinned] = before;
        cascadeSeparate(
          movedIds: {pinned},
          positions: positions,
          dimsFor: dims,
          allIds: positions.keys,
        );
        expect(positions[pinned], before, reason: 'trial $trial');
        expect(_crowdedPairs(positions, dims), isEmpty, reason: 'trial $trial');
      }
    });

    test('pushes a card off a second pinned card', () {
      // Two pinned cards side by side and one free card overlapping both.
      final positions = <String, Offset>{
        'left': Offset.zero,
        'right': const Offset(400, 0),
        'free': const Offset(150, 20),
      };
      cascadeSeparate(
        movedIds: {'left', 'right'},
        positions: positions,
        dimsFor: dims,
        allIds: positions.keys,
      );
      expect(positions['left'], Offset.zero);
      expect(positions['right'], const Offset(400, 0));
      expect(_crowdedPairs(positions, dims), isEmpty);
    });

    test('leaves pinned cards where they are', () {
      final positions = <String, Offset>{
        'a': Offset.zero,
        'b': const Offset(10, 10),
      };
      cascadeSeparate(
        movedIds: {'a'},
        positions: positions,
        dimsFor: dims,
        allIds: positions.keys,
      );
      expect(positions['a'], Offset.zero);
      expect(_crowdedPairs(positions, dims), isEmpty);
    });
  });
}
