// Contract for what the shared widgets (packages/widgets) show to
// accessibility clients: VoiceOver, and agents such as apprentice that
// drive the app through the macOS accessibility tree and only click what
// it lists as a named button or field.
// * AppButton and AppToggleButton read as buttons named by their text,
//   enabled only with an onPressed; the toggle also says on or off.
// * An AppTabBar tab reads as a button named by its label, and the open
//   tab is marked selected.
// * InstantDropdown reads as one button named by its field label, with the
//   current choice as its value; with no label, the choice is the name.
// * FieldName puts the field's name in its own text node on macOS, where
//   Flutter drops a text field's label, and adds nothing elsewhere.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widgets/widgets.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(extensions: const [vsCodeDarkPalette]),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('AppButton reads as a named button, enabled only with onPressed', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(Row(children: [
        AppButton(onPressed: () {}, child: const Text('Save')),
        const AppButton(onPressed: null, child: Text('Delete')),
      ])),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Save')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Delete')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );
    handle.dispose();
  });

  testWidgets('AppToggleButton reads as a button that says whether it is on', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(Row(children: [
        AppToggleButton(selected: true, onPressed: () {}, child: const Text('Typed')),
        AppToggleButton(selected: false, onPressed: () {}, child: const Text('Plain')),
      ])),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Typed')),
      isSemantics(isButton: true, hasToggledState: true, isToggled: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Plain')),
      isSemantics(isButton: true, hasToggledState: true, isToggled: false),
    );
    handle.dispose();
  });

  testWidgets('an AppTabBar tab reads as a button and the open one is selected', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(AppTabBar(
        index: 1,
        onChanged: (_) {},
        tabs: const [
          AppTab(label: 'General', child: SizedBox()),
          AppTab(label: 'Advanced', child: SizedBox()),
        ],
      )),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('General')),
      isSemantics(isButton: true, isSelected: false, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Advanced')),
      isSemantics(isButton: true, isSelected: true, hasTapAction: true),
    );
    handle.dispose();
  });

  testWidgets('InstantDropdown reads as a button named by its label with the choice as value', (tester) async {
    final handle = tester.ensureSemantics();
    final items = [
      InstantDropdownItem(label: 'Postgres', selected: true, onSelected: () {}),
      InstantDropdownItem(label: 'SQLite', selected: false, onSelected: () {}),
    ];
    await tester.pumpWidget(
      _host(SizedBox(
        width: 200.0,
        child: Column(children: [
          InstantDropdown(items: items, decoration: const InputDecoration(labelText: 'Kind')),
          InstantDropdown(items: items),
        ]),
      )),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Kind')),
      isSemantics(isButton: true, value: 'Postgres', hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Postgres')),
      isSemantics(isButton: true, hasTapAction: true),
    );
    handle.dispose();
  });

  group('FieldName', () {
    Widget field() => _host(const SizedBox(width: 200.0, child: FieldName('Host', child: TextField())));

    testWidgets('names the field in its own text node on macOS', (tester) async {
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(field());

      final name = tester.getSemantics(find.bySemanticsLabel('Host'));
      expect(name, isNot(isSemantics(isTextField: true)));
      expect(name.rect.size, tester.getSize(find.byType(TextField)));

      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    });

    testWidgets('adds nothing on other platforms', (tester) async {
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(field());

      expect(find.bySemanticsLabel('Host'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    });
  });
}
