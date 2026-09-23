// Test double for DbExecutor. Records every execute() call so a test can
// assert on the SQL text and parameters dbscope produced for a given
// operation. Returns whatever DbResult was set up via [enqueue]; defaults
// to an empty result.

import 'package:dbscope/db/executor.dart';
import 'package:dbscope/query/cancel_token.dart';

class ExecuteCall {
  final String sql;
  final List<Object?>? positional;
  final Map<String, Object?>? named;
  const ExecuteCall(this.sql, {this.positional, this.named});
}

class FakeDbExecutor implements DbExecutor {
  final List<ExecuteCall> calls = [];
  final List<DbResult> _scripted = [];
  bool _open = true;
  bool readOnly = false;

  @override
  String get kind => 'fake';

  @override
  bool get isOpen => _open;

  @override
  DbCapabilities get capabilities => const DbCapabilities(
    sessionReadOnly: true,
    cancelByClose: false,
    dml: true,
    transactions: true,
  );

  /// Queue a result to be returned by the next execute() call. Calls
  /// beyond the queued list get an empty result with zero affectedRows.
  void enqueue(DbResult result) => _scripted.add(result);

  void enqueueAffected(int affectedRows) {
    _scripted.add(
      DbResult(
        columns: const [],
        rows: const [],
        affectedRows: affectedRows,
      ),
    );
  }

  void enqueueRow(List<Object?> row, {List<String> columns = const []}) {
    _scripted.add(
      DbResult(
        columns: [for (final c in columns) DbColumn(name: c)],
        rows: [row],
      ),
    );
  }

  @override
  Future<DbResult> execute(
    String sql, {
    List<Object?>? positional,
    Map<String, Object?>? named,
    CancelToken? cancelToken,
  }) async {
    calls.add(ExecuteCall(sql, positional: positional, named: named));
    if (_scripted.isNotEmpty) return _scripted.removeAt(0);
    return const DbResult(columns: [], rows: []);
  }

  @override
  Future<void> setReadOnly(bool value) async {
    readOnly = value;
  }

  @override
  Future<void> close({bool force = false}) async {
    _open = false;
  }
}
