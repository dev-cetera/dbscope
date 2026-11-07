// Contract: SqliteExecutor reports affectedRows for the statement it just
// ran: the rows an INSERT / UPDATE / DELETE changed, and 0 for a statement
// that changed none (DDL, a no-match UPDATE), never the count left over
// from an earlier write. A RowCap never returns more rows than it allows,
// says when it left some out, and doesn't stop a write part way.

import 'package:dbscope/db/executor.dart';
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

  group('RowCap', () {
    test('a read past the cap is cut and says so', () async {
      final result = await executor.execute(
        'SELECT id, name FROM t ORDER BY id',
        rowCap: const RowCap(2, mode: RowCapMode.stopAtLimit),
      );
      expect(result.rows, [
        [1, 'a'],
        [2, 'b'],
      ]);
      expect(result.columns.map((column) => column.name), ['id', 'name']);
      expect(result.truncated, isTrue);
    });

    test('a read that fits the cap is not truncated', () async {
      final result = await executor.execute(
        'SELECT id FROM t',
        rowCap: const RowCap(3, mode: RowCapMode.stopAtLimit),
      );
      expect(result.rows, hasLength(3));
      expect(result.truncated, isFalse);
    });

    test('duplicate column names keep both values', () async {
      final result = await executor.execute(
        'SELECT 1 AS a, 2 AS a',
        rowCap: const RowCap(5, mode: RowCapMode.stopAtLimit),
      );
      expect(result.rows.single, [1, 2]);
    });

    test('a write past the cap still changes every row', () async {
      final result = await executor.execute(
        "UPDATE t SET name = 'z' RETURNING id",
        rowCap: const RowCap(1, mode: RowCapMode.readAndDrop),
      );
      expect(result.rows, hasLength(1));
      expect(result.truncated, isTrue);
      final changed = await executor.execute("SELECT count(*) FROM t WHERE name = 'z'");
      expect(changed.rows.single.single, 3);
    });

    test('DDL under a cap reports no rows', () async {
      final result = await executor.execute(
        'CREATE TABLE v (id INTEGER)',
        rowCap: const RowCap(5, mode: RowCapMode.readAndDrop),
      );
      expect(result.columns, isEmpty);
      expect(result.truncated, isFalse);
    });

    test('bound parameters work under a cap', () async {
      final positional = await executor.execute(
        r'SELECT name FROM t WHERE id = $1',
        positional: [2],
        rowCap: const RowCap(5, mode: RowCapMode.stopAtLimit),
      );
      expect(positional.rows.single.single, 'b');
      final named = await executor.execute(
        'SELECT name FROM t WHERE id = @id',
        named: {'id': 3},
        rowCap: const RowCap(5, mode: RowCapMode.stopAtLimit),
      );
      expect(named.rows.single.single, 'c');
    });
  });
}
