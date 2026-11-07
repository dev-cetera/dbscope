// Contract: AppState.cancelAll asks every running tab to stop and returns the
// connections Stop has to close, going by each tab's own connection, not the
// active one. A connection is closed only when asking can't be enough: its
// backend can't stop a running statement, a running tab has no token, or a tab
// was asked and is still running. A first press on an ordinary Postgres query
// closes nothing, or Stop would drop the connection and any open transaction
// every time. untilCancelled stops the wait for work that can't be aborted, which
// is how Stop ends an AI request.

import 'dart:async';

import 'package:dbscope/query/cancel_token.dart';
import 'package:dbscope/query/query_tab_kind.dart';
import 'package:dbscope/shell/app_state.dart';
import 'package:dbscope/tabs/tab_kind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() {
    if (TabKindRegistry.instance.lookupById(queryTabKind.id) == null) {
      TabKindRegistry.instance.register(queryTabKind);
    }
  });

  QueryTab running({CancelToken? token, String connectionId = 'pg'}) {
    final tab = QueryTab(connectionId: connectionId, isLoading: true)..cancelToken = token;
    AppState.instance.openTab(tab);
    addTearDown(() => AppState.instance.tabs.remove(tab));
    return tab;
  }

  Set<String> press() => AppState.instance.cancelAll(canStopStatements: (id) => id == 'pg');

  test('the first press on a backend that can stop asks, and closes nothing', () {
    final token = CancelToken();
    running(token: token);
    expect(press(), isEmpty);
    expect(token.isCancelled, isTrue);
  });

  test('a second press on a tab still running closes its connection', () {
    running(token: CancelToken());
    press();
    expect(press(), {'pg'});
  });

  test('a running tab with no token closes its connection', () {
    running();
    expect(press(), {'pg'});
  });

  test('a backend that cannot stop a statement is closed on the first press', () {
    final token = CancelToken();
    running(token: token, connectionId: 'sqlite');
    expect(press(), {'sqlite'});
    expect(token.isCancelled, isTrue);
  });

  test('each tab decides for its own connection', () {
    running(token: CancelToken());
    running(token: CancelToken(), connectionId: 'sqlite');
    expect(press(), {'sqlite'});
  });

  test('a tab that is not running closes nothing', () {
    final idle = QueryTab(connectionId: 'sqlite');
    AppState.instance.openTab(idle);
    addTearDown(() => AppState.instance.tabs.remove(idle));
    expect(press(), isEmpty);
  });

  group('untilCancelled', () {
    test('returns the result when the work finishes first', () async {
      expect(await untilCancelled(Future.value('sql'), CancelToken()), 'sql');
    });

    test('returns null at once when cancelled, without waiting for the work', () async {
      final work = Completer<String>();
      final token = CancelToken();
      final waiting = untilCancelled(work.future, token);
      token.cancel();
      expect(await waiting, isNull);
      expect(work.isCompleted, isFalse);
    });

    test('a failure after the cancel goes nowhere', () async {
      final work = Completer<String>();
      final token = CancelToken();
      final waiting = untilCancelled(work.future, token);
      token.cancel();
      await waiting;
      work.completeError(StateError('late failure'));
    });
  });
}
