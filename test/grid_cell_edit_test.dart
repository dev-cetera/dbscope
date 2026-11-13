// Inline cell editing in DataGrid. An editor reports every keystroke
// through CellEditContext.onChanged; only the grid ends the edit.
// * A single click selects at once, even on an editable cell: it never
//   waits out the double-click window first.
// * Double-tapping an editable cell opens its editor with keyboard focus
//   on the input, so the user can type straight away. Two clicks further
//   apart than the double-click window don't.
// * Typing keeps the editor open and reports nothing to onCellEdit.
// * Enter commits the typed value once; clicking another cell commits
//   it too; Esc discards it.
// * While editing, the grid's own arrow / Cmd-A shortcuts stand down so
//   the key reaches the input.

import 'package:data_grid/data_grid.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _TextEditor extends CellEditor<String> {
  const _TextEditor();

  @override
  bool canEdit(GridColumnSpec<String> column) => true;

  @override
  Widget build(BuildContext context, CellEditContext<String> editContext) {
    return TextField(
      controller: TextEditingController(text: '${editContext.value}'),
      focusNode: editContext.focusNode,
      onChanged: editContext.onChanged,
    );
  }
}

GridData<String> _data() => const GridData<String>(
  columns: [GridColumnSpec<String>(name: 'name')],
  rows: [
    <Object?>['alice'],
    <Object?>['bob'],
  ],
);

Future<List<GridEditEvent>> _pumpGrid(
  WidgetTester tester, {
  void Function(int? rowIdx)? onRowSelected,
}) async {
  final edits = <GridEditEvent>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DataGrid<String>(
          data: _data(),
          cellEditor: const _TextEditor(),
          onCellEdit: edits.add,
          onRowSelected: onRowSelected,
        ),
      ),
    ),
  );
  return edits;
}

Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(kDoubleTapMinTime);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

EditableText _editable(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText));

void main() {
  testWidgets('a single click on an editable cell selects without waiting', (tester) async {
    final selectedRows = <int?>[];
    await _pumpGrid(tester, onRowSelected: selectedRows.add);

    await tester.tap(find.text('bob'));
    await tester.pump();

    expect(selectedRows, [1]);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('two clicks further apart than the double-click window do not edit', (
    tester,
  ) async {
    await _pumpGrid(tester);

    await tester.tap(find.text('alice'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    await tester.tap(find.text('alice'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('double-tap focuses the input and typing keeps the editor open', (tester) async {
    final edits = await _pumpGrid(tester);
    await _doubleTap(tester, find.text('alice'));

    expect(find.byType(TextField), findsOneWidget);
    expect(_editable(tester).focusNode.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'alicia');
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget, reason: 'one keystroke must not end the edit');
    expect(edits, isEmpty);
  });

  testWidgets('Enter commits the typed value once', (tester) async {
    final edits = await _pumpGrid(tester);
    await _doubleTap(tester, find.text('alice'));
    await tester.enterText(find.byType(TextField), 'alicia');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.byType(TextField), findsNothing);
    expect(edits, hasLength(1));
    expect(edits.single.rowIdx, 0);
    expect(edits.single.oldValue, 'alice');
    expect(edits.single.newValueRaw, 'alicia');
  });

  testWidgets('clicking another cell commits the typed value', (tester) async {
    final edits = await _pumpGrid(tester);
    await _doubleTap(tester, find.text('alice'));
    await tester.enterText(find.byType(TextField), 'alicia');
    await tester.tap(find.text('bob'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(edits.map((edit) => edit.newValueRaw), ['alicia']);
  });

  testWidgets('Esc discards the typed value', (tester) async {
    final edits = await _pumpGrid(tester);
    await _doubleTap(tester, find.text('alice'));
    await tester.enterText(find.byType(TextField), 'alicia');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.byType(TextField), findsNothing);
    expect(edits, isEmpty);
  });

  testWidgets('arrow keys move the caret, not the grid selection', (tester) async {
    await _pumpGrid(tester);
    await _doubleTap(tester, find.text('alice'));
    final controller = _editable(tester).controller;
    controller.selection = const TextSelection.collapsed(offset: 5);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
  });
}
