// Contract: SqliteExecutor reports affectedRows for the statement it just
// ran: the rows an INSERT / UPDATE / DELETE changed, and 0 for a statement
// that changed none (DDL, a no-match UPDATE), never the count left over
// from an earlier write.

import 'package:dbscope/db/sqlite_executor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

void main() {
  late SqliteExecutor executor;

  setUp(() {
    final db = sq.sqlite3.openInMemory();
    executor = SqliteExecutor(db);
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    db.execute("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')");
  });

  tearDown(() => executor.close());

  test('an UPDATE reports the rows it changed', () async {
    final result = await executor.execute("UPDATE t SET name = 'z'");
    expect(result.affectedRows, 3);
  });

  test('DDL after an UPDATE reports 0, not the UPDATE count', () async {
    await executor.execute("UPDATE t SET name = 'z'");
    final result = await executor.execute('CREATE TABLE u (id INTEGER)');
    expect(result.affectedRows, 0);
  });

  test('a bound UPDATE that matches nothing reports 0', () async {
    await executor.execute("UPDATE t SET name = 'z'");
    final result = await executor.execute(
      r'UPDATE t SET name = $1 WHERE id = $2',
      positional: ['y', 99],
    );
    expect(result.affectedRows, 0);
  });
}
