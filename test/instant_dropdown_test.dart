// Contract for InstantDropdown (packages/widgets):
// * The button shows the selected item's label, or the hint when none is
//   selected.
// * A click shows the whole menu on the very next frame: no open
//   animation to wait out (DropdownButton's takes 300 ms).
// * Picking an item calls that item's onSelected; a disabled dropdown
//   doesn't open, and a disabled item can't be picked.
// * With a decoration it draws as a form field showing that label.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widgets/widgets.dart';

Widget _host(InstantDropdown dropdown) =>
    MaterialApp(home: Scaffold(body: Center(child: dropdown)));

List<InstantDropdownItem> _items(String? selected, List<String> picks) => [
  for (final label in ['red', 'green'])
    InstantDropdownItem(
      label: label,
      selected: label == selected,
      onSelected: () => picks.add(label),
    ),
];

void main() {
  testWidgets('shows the selected label, or the hint when none is selected', (tester) async {
    await tester.pumpWidget(_host(InstantDropdown(items: _items('green', []))));
    expect(find.text('green'), findsOneWidget);

    await tester.pumpWidget(_host(InstantDropdown(hint: 'pick', items: _items(null, []))));
    expect(find.text('pick'), findsOneWidget);
  });

  testWidgets('a click shows the menu on the next frame and picking calls onSelected', (
    tester,
  ) async {
    final picks = <String>[];
    await tester.pumpWidget(_host(InstantDropdown(items: _items('green', picks))));

    await tester.tap(find.text('green'));
    await tester.pump();

    final redItem = find.text('red');
    expect(redItem, findsOneWidget);
    final menuRoute = ModalRoute.of(tester.element(redItem))!;
    expect(menuRoute.animation!.status, AnimationStatus.completed);

    await tester.tap(
      find.ancestor(of: redItem, matching: find.byWidgetPredicate((w) => w is PopupMenuEntry)),
    );
    await tester.pump();
    expect(picks, ['red']);
  });

  testWidgets('a disabled dropdown does not open', (tester) async {
    await tester.pumpWidget(
      _host(InstantDropdown(enabled: false, items: _items('green', []))),
    );

    await tester.tap(find.text('green'));
    await tester.pump();

    expect(find.text('red'), findsNothing);
  });

  testWidgets('a disabled item cannot be picked', (tester) async {
    final picks = <String>[];
    await tester.pumpWidget(
      _host(
        InstantDropdown(
          items: [
            InstantDropdownItem(label: 'on', selected: true, onSelected: () => picks.add('on')),
            InstantDropdownItem(
              label: 'off',
              selected: false,
              enabled: false,
              onSelected: () => picks.add('off'),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('on'));
    await tester.pump();
    await tester.tap(find.text('off'), warnIfMissed: false);
    await tester.pump();

    expect(picks, isEmpty);
  });

  testWidgets('with a decoration it shows the field label', (tester) async {
    await tester.pumpWidget(
      _host(
        InstantDropdown(
          decoration: const InputDecoration(labelText: 'SSL mode'),
          items: _items('green', []),
        ),
      ),
    );

    expect(find.text('SSL mode'), findsOneWidget);
    expect(find.text('green'), findsOneWidget);
  });
}
