// Contract: startup and connection defaults hold up against bad input.
//
// * suggestSslMode: a database on this machine defaults to `disable`, any
//   other host to `require`, so a new remote profile never sends its
//   password in the clear by default.
// * restorePersistedTabs: a saved tab entry this build can't read (wrong
//   field types, unknown shape) is skipped; the readable tabs still come
//   back and the call never throws. It runs before the first frame, so a
//   throw would fail every launch.

import 'dart:convert';

import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/query/query_tab_kind.dart';
import 'package:dbscope/shell/app_state.dart';
import 'package:dbscope/shell/ui_prefs.dart';
import 'package:dbscope/tabs/tab_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('suggestSslMode', () {
    test('local hosts default to disable', () {
      for (final host in ['localhost', '127.0.0.1', '::1', '', ' LOCALHOST ']) {
        expect(suggestSslMode(host), SslMode.disable, reason: host);
      }
    });

    test('remote hosts default to require', () {
      for (final host in ['db.example.com', '10.0.0.5', 'my-instance.rds.amazonaws.com']) {
        expect(suggestSslMode(host), SslMode.require, reason: host);
      }
    });
  });

  group('restorePersistedTabs', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      if (TabKindRegistry.instance.lookupById(queryTabKind.id) == null) {
        TabKindRegistry.instance.register(queryTabKind);
      }
    });

    test('skips unreadable entries and keeps the rest', () async {
      SharedPreferences.setMockInitialValues({
        'ui.openTabs': jsonEncode({
          'activeId': 42,
          'tabs': [
            {'kind': 7},
            {'kind': 'query', 'id': 'bad', 'sql': 12345},
            {'kind': 'query', 'id': 'good', 'connectionId': 'c', 'sql': 'select 1'},
            'not a map',
          ],
        }),
      });
      await UiPrefs.instance.init();

      expect(AppState.instance.restorePersistedTabs, returnsNormally);
      expect([for (final tab in AppState.instance.tabs) tab.id], ['good']);
    });
  });
}
