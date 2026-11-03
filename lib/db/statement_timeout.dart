// Pure-Dart (web-safe) interface for executors that can stop their own
// statement at a deadline. Postgres doesn't need it (`SET LOCAL
// statement_timeout` does the job server-side); SQLite has no such setting,
// so `SqliteExecutor` implements it with a progress handler.

/// An executor that can abort whatever statement `body` runs once `timeout`
/// has elapsed. The aborted statement fails with a [StatementTimedOut].
abstract interface class StatementTimeoutCapable {
  Future<T> withStatementTimeout<T>(
    Duration timeout,
    Future<T> Function() body,
  );
}

/// Thrown when a statement is stopped by [StatementTimeoutCapable].
class StatementTimedOut implements Exception {
  const StatementTimedOut(this.timeout);
  final Duration timeout;

  @override
  String toString() =>
      'The statement ran longer than ${timeout.inMilliseconds} ms and was '
      'stopped.';
}
