// Contract: DeviceSqliteExecutor (on-device SQLite, pull-edit-push) pushes
// the local file back to the phone only when a statement changed it, and
// only once no transaction is open.
// * A SELECT that returns rows never pushes (it used to: the row count was
//   read as "rows affected").
// * Row writes (also inside a WITH, or an INSERT … RETURNING), schema
//   changes and keyword-only writes (PRAGMA user_version = N) push once.
// * Writes inside BEGIN … COMMIT push once, at the COMMIT.

import 'dart:io';

import 'package:app_data_explorer/app_data_explorer.dart';
import 'package:dbscope_sqflite_plugin/dbscope_sqflite_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

/// A phone whose app container is a local directory. Counts pushes.
class _FakeDevice implements Backend {
  _FakeDevice(this.root);
  final Directory root;
  var pushes = 0;

  File _file(String rel) => File('${root.path}/$rel');

  @override
  String get deviceLabel => 'fake';
  @override
  String get appLabel => 'app';
  @override
  Future<List<Entry>> ls(String relPath) async => const [];
  @override
  Future<List<Entry>> lsRecursive(String relPath) async => const [];
  @override
  Future<void> clearDir(String relDir) async {}
  @override
  Future<void> rm(String relPath) async {
    final file = _file(relPath);
    if (file.existsSync()) file.deleteSync();
  }

  @override
  Future<void> pull(String remoteRelPath, String localPath) async {
    final file = _file(remoteRelPath);
    if (!file.existsSync()) throw const FileSystemException('absent');
    file.copySync(localPath);
  }

  @override
  Future<void> push(String localPath, String remoteRelPath) async {
    pushes++;
    File(localPath).copySync(_file(remoteRelPath).path);
  }
}

void main() {
  late Directory root;
  late _FakeDevice device;
  late DeviceSqliteExecutor executor;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('dbscope_fake_device_');
    final db = sq.sqlite3.open('${root.path}/app.db');
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    db.execute("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')");
    db.dispose();
    device = _FakeDevice(root);
    executor = await DeviceSqliteExecutor.open(backend: device, remoteDbPath: 'app.db');
  });

  tearDown(() async {
    await executor.close();
    root.deleteSync(recursive: true);
  });

  test('a SELECT that returns rows does not push', () async {
    final result = await executor.execute('SELECT * FROM t');
    expect(result.rows, hasLength(3));
    await executor.execute(r'SELECT * FROM t WHERE id > $1', positional: [1]);
    await executor.execute('/* c */ SELECT 1');
    await executor.execute('PRAGMA table_info(t)');
    expect(device.pushes, 0);
  });

  test('an UPDATE pushes once and the device gets the change', () async {
    await executor.execute(r'UPDATE t SET name = $1 WHERE id = $2', positional: ['z', 1]);
    expect(device.pushes, 1);
    final onDevice = sq.sqlite3.open('${root.path}/app.db');
    addTearDown(onDevice.dispose);
    expect(onDevice.select('SELECT name FROM t WHERE id = 1').first['name'], 'z');
  });

  test('a write inside WITH, and INSERT RETURNING, push', () async {
    await executor.execute('WITH x AS (SELECT 1) DELETE FROM t WHERE id = 3');
    expect(device.pushes, 1);
    await executor.execute(r'INSERT INTO t (name) VALUES ($1) RETURNING id', positional: ['d']);
    expect(device.pushes, 2);
  });

  test('schema changes and writing pragmas push', () async {
    await executor.execute('CREATE TABLE u (id INTEGER)');
    expect(device.pushes, 1);
    await executor.execute('PRAGMA user_version = 7');
    expect(device.pushes, 2);
  });

  test('writes inside a transaction push once, at COMMIT', () async {
    await executor.execute('BEGIN');
    await executor.execute("INSERT INTO t (name) VALUES ('x')");
    await executor.execute("INSERT INTO t (name) VALUES ('y')");
    expect(device.pushes, 0);
    await executor.execute('COMMIT');
    expect(device.pushes, 1);
  });
}
