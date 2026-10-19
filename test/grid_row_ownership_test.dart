// The DataGrid owns its own row list. TableTabView keeps its tab buffer
// in sync by mutating that buffer itself AND telling the grid through
// DataGridController (appendRows / removeFirstRows / removeRowAt /
// prependRow). If the grid stored the caller's list instead of a copy,
// every one of those mutations would land twice: a loaded page shows up
// twice, a delete also removes the row below it, an insert appears twice.
// * replaceAll / initial data are copied (outer list only).
// * Each controller mutation changes the grid's rows exactly once.
// * The selection follows its row across those mutations, and is
//   dropped when its row is removed — the inspector reads it, so a stale
//   index would show (and edit) the wrong row.
// * A column-resize drag tracks total pointer travel: pointer events
//   that arrive between rebuilds are not lost.

import 'package:data_grid/data_grid.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GridData<String> _data(Iterable<String> ids) => GridData<String>(
  columns: const [GridColumnSpec<String>(name: 'id')],
  rows: [
    for (final id in ids) <Object?>[id],
  ],
);

void main() {
  testWidgets('controller mutations mirrored by the caller apply once', (
    tester,
  ) async {
    final controller = DataGridController<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataGrid<String>(
            data: _data(const []),
            controller: controller,
          ),
        ),
      ),
    );

    // Mirrors TableTabView: replaceAll(tab.data), then mutate tab.data
    // in place and forward the same delta to the controller.
    final tabData = _data(['r0', 'r1', 'r2']);
    controller.replaceAll(tabData);
    await tester.pump();

    final page = [
      <Object?>['r3'],
      <Object?>['r4'],
    ];
    tabData.rows.addAll(page);
    controller.appendRows(page);
    await tester.pump();
    for (final id in ['r0', 'r1', 'r2', 'r3', 'r4']) {
      expect(find.text(id), findsOneWidget, reason: 'after append: $id');
    }

    tabData.rows.removeAt(0);
    controller.removeRowAt(0);
    await tester.pump();
    expect(find.text('r0'), findsNothing);
    for (final id in ['r1', 'r2', 'r3', 'r4']) {
      expect(find.text(id), findsOneWidget, reason: 'after delete: $id');
    }

    final inserted = <Object?>['new'];
    tabData.rows.insert(0, inserted);
    controller.prependRow(inserted);
    await tester.pump();
    expect(find.text('new'), findsOneWidget);

    tabData.rows.removeRange(0, 2);
    controller.removeFirstRows(2);
    await tester.pump();
    expect(find.text('new'), findsNothing);
    expect(find.text('r1'), findsNothing);
    for (final id in ['r2', 'r3', 'r4']) {
      expect(find.text(id), findsOneWidget, reason: 'after trim: $id');
    }
  });

  group('GridModel selection follows row mutations', () {
    GridModel model() => GridModel()
      ..resetColumns(2, const [100.0, 100.0])
      ..setRowCount(10);

    test('removing a row above shifts the selection up', () {
      final m = model()..selectSingle(5, 1);
      m.rowsRemoved(2, 1);
      expect(m.selection?.focusRow, 4);
      expect(m.selection?.focusCol, 1);
    });

    test('removing the selected row drops the selection', () {
      final m = model()..selectSingle(5, 0);
      m.rowsRemoved(5, 1);
      expect(m.selection, isNull);
    });

    test('removing a row below leaves the selection alone', () {
      final m = model()..selectSingle(5, 0);
      m.rowsRemoved(7, 1);
      expect(m.selection?.focusRow, 5);
    });

    test('trimming the top shifts or drops the selection', () {
      final kept = model()..selectSingle(5, 0);
      kept.rowsRemoved(0, 3);
      expect(kept.selection?.focusRow, 2);
      final dropped = model()..selectSingle(1, 0);
      dropped.rowsRemoved(0, 3);
      expect(dropped.selection, isNull);
    });

    test('a prepended row pushes the selection down', () {
      final m = model()..selectSingle(5, 0);
      m.rowsInserted(0, 1);
      expect(m.selection?.focusRow, 6);
    });

    test('an in-progress edit follows its row', () {
      final m = model()..beginEdit(5, 1);
      m.rowsInserted(0, 1);
      expect(m.editingRow, 6);
      m.rowsRemoved(6, 1);
      expect(m.editingRow, isNull);
      expect(m.editingCol, isNull);
    });
  });

  testWidgets('column resize keeps every pointer delta between rebuilds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataGrid<String>(data: _data(['r0'])),
        ),
      ),
    );
    final handle = find.byWidgetPredicate(
      (widget) => widget is MouseRegion && widget.cursor == SystemMouseCursors.resizeColumn,
    );
    final before = tester.getRect(handle).right;
    final gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    // No pump between moves: several events land on one build.
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(10.0, 0.0));
    }
    await gesture.up();
    await tester.pump();
    final after = tester.getRect(handle).right;
    // Pre-fix this was 10: each update added its delta to the width from
    // the last build, so only the final event's delta survived.
    expect(after - before, 40.0);
  });
}
