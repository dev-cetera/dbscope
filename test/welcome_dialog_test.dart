// Tests for the first-run welcome dialog. The contract it pins down: the
// dialog opens by itself only for someone new to dbscope (never closed it
// before, no saved connections, not launched to auto-connect), and its
// buttons report which way the user left it so the caller can start the
// new-connection flow.

import 'package:dbscope/shell/welcome_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldShowWelcome', () {
    test('shows for a brand-new user', () {
      expect(
        shouldShowWelcome(seen: null, hasSavedProfiles: false, autoConnecting: false),
        isTrue,
      );
    });

    test('stays closed once it was seen', () {
      expect(
        shouldShowWelcome(seen: true, hasSavedProfiles: false, autoConnecting: false),
        isFalse,
      );
    });

    test('stays closed when connections are already saved', () {
      expect(
        shouldShowWelcome(seen: false, hasSavedProfiles: true, autoConnecting: false),
        isFalse,
      );
    });

    test('stays closed when a command-line launch is connecting', () {
      expect(
        shouldShowWelcome(seen: false, hasSavedProfiles: false, autoConnecting: true),
        isFalse,
      );
    });
  });

  group('showWelcomeDialog', () {
    // Opens the dialog and hands back its result, wrapped so the caller
    // can tap first and await after.
    Future<({Future<WelcomeChoice?> choice})> open(WidgetTester tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final choice = showWelcomeDialog(context);
      await tester.pumpAndSettle();
      return (choice: choice);
    }

    testWidgets('Add a connection reports addConnection', (tester) async {
      final opened = await open(tester);
      expect(find.text('Welcome to dbscope'), findsOneWidget);
      await tester.tap(find.text('Add a connection…'));
      await tester.pumpAndSettle();
      expect(await opened.choice, WelcomeChoice.addConnection);
      expect(find.text('Welcome to dbscope'), findsNothing);
    });

    testWidgets('Not now reports close', (tester) async {
      final opened = await open(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await opened.choice, WelcomeChoice.close);
    });
  });
}
