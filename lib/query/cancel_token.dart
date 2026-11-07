import 'dart:async';

/// Waits for [work], or returns null as soon as [token] is cancelled. [work]
/// can't be stopped from here: it runs on and its result is dropped. For calls
/// with no way to abort them, so a Stop doesn't leave the caller waiting.
Future<T?> untilCancelled<T extends Object>(Future<T> work, CancelToken token) =>
    Future.any<T?>([work, token.whenCancelled.then((_) => null)]);

class CancelToken {
  var _cancelled = false;
  final _completer = Completer<void>();

  bool get isCancelled => _cancelled;

  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}
