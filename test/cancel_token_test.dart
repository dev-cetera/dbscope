// CancelToken backs the user-facing Stop button across every executor.
// The contract is small but load-bearing: cancel() is idempotent, the
// future completes exactly once, and isCancelled flips synchronously.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dbscope/query/cancel_token.dart';

void main() {
  test('starts uncancelled', () {
    final token = CancelToken();
    expect(token.isCancelled, isFalse);
  });

  test('cancel flips isCancelled synchronously', () {
    final token = CancelToken();
    token.cancel();
    expect(token.isCancelled, isTrue);
  });

  test('whenCancelled completes after cancel', () async {
    final token = CancelToken();
    var completed = false;
    final waiter = token.whenCancelled.then((_) => completed = true);
    expect(completed, isFalse);
    token.cancel();
    await waiter;
    expect(completed, isTrue);
  });

  test('cancel is idempotent — calling twice does not throw', () {
    final token = CancelToken();
    token.cancel();
    expect(token.cancel, returnsNormally);
    expect(token.isCancelled, isTrue);
  });

  test(
    'whenCancelled future fires exactly once even after multiple cancels',
    () async {
      final token = CancelToken();
      var fires = 0;
      final waiter = token.whenCancelled.then((_) => fires++);
      token.cancel();
      token.cancel();
      token.cancel();
      await waiter;
      // Give microtask queue a beat to settle.
      await Future<void>.delayed(Duration.zero);
      expect(fires, 1);
    },
  );

  test('whenCancelled resolves before a delayed observer fires', () async {
    final token = CancelToken();
    final completer = Completer<bool>();
    token.whenCancelled.then((_) => completer.complete(token.isCancelled));
    token.cancel();
    expect(await completer.future, isTrue);
  });
}
