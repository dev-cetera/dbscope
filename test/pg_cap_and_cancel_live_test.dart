// Contract: on a real server, cancelling a token stops the running statement
// and keeps the connection; a row cap never returns more rows than asked, and
// on a plain read the server never produces the rest. Writes and open
// transactions survive, and a capped read never opens a transaction of its own
// that could commit another tab's work. The same holds through the web proxy, and both show a value as the
// same text. Clients vanishing mid-statement don't take the proxy down. Skipped unless DBSCOPE_LIVE_PG is set:
//
//   DBSCOPE_LIVE_PG=1 PGHOST=localhost PGUSER=postgres PGPASSWORD=… \
//     fvm flutter test test/pg_cap_and_cancel_live_test.dart
//
// Set DBSCOPE_LIVE_PROXY_URL (ws://…) to run the group for a running
// `dbscope_pg_proxy` as well.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbscope/catalog/schema_catalog.dart';
import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/executor.dart';
import 'package:dbscope/db/postgres_executor.dart';
import 'package:dbscope/db/postgres_plugin.dart';
import 'package:dbscope/query/cancel_token.dart';
import 'package:dbscope/query/pager.dart';
import 'package:dbscope/query/runner.dart';
import 'package:dbscope/server/jobs/copy_table_job.dart';
import 'package:dbscope_pg_proxy_plugin/src/executor.dart';
import 'package:flutter_test/flutter_test.dart';

String _env(String name, String fallback) => Platform.environment[name] ?? fallback;

const _kCap = RowCap(10, mode: RowCapMode.stopAtLimit);

/// Far more rows than it would take to notice an uncancelled read: this would
/// run for many minutes if the cap didn't stop it. In the SELECT list on
/// purpose: `FROM generate_series(...)` writes every row to a temp file before
/// returning the first.
const _kEndless = 'SELECT generate_series(1, 2000000000)';

void _sharedContract(DbExecutor Function() executor) {
  test('cancelling stops a running statement and keeps the connection', () async {
    final token = CancelToken();
    final stopwatch = Stopwatch()..start();
    final running = executor().execute('SELECT pg_sleep(60)', cancelToken: token);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    token.cancel();
    final result = await running;
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
    expect(result.rows, isEmpty);
    expect((await executor().execute('SELECT 1')).rows.first.first, 1);
  });

  test('a stopping cap ends an endless read at once', () async {
    final stopwatch = Stopwatch()..start();
    final result = await executor().execute(_kEndless, rowCap: _kCap);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(result.rows, hasLength(10));
    expect(result.truncated, isTrue);
    expect((await executor().execute('SELECT 1')).rows.first.first, 1);
  });

  test('a result within the cap is not truncated', () async {
    final result = await executor().execute(
      'SELECT g FROM generate_series(1, 10) g',
      rowCap: _kCap,
    );
    expect(result.rows, hasLength(10));
    expect(result.truncated, isFalse);
  });

  test('a write past the cap still commits every row', () async {
    await executor().execute('DROP TABLE IF EXISTS dbscope_cap_live');
    await executor().execute('CREATE TABLE dbscope_cap_live (id int)');
    try {
      final result = await executor().execute(
        'INSERT INTO dbscope_cap_live SELECT g FROM generate_series(1, 50) g RETURNING id',
        rowCap: const RowCap(10, mode: RowCapMode.readAndDrop),
      );
      expect(result.rows, hasLength(10));
      expect(result.truncated, isTrue);
      final count = await executor().execute('SELECT count(*)::int FROM dbscope_cap_live');
      expect(count.rows.first.first, 50);
    } finally {
      await executor().execute('DROP TABLE dbscope_cap_live');
    }
  });

  test('the query runner keeps an open transaction past the cap', () async {
    await executor().execute('DROP TABLE IF EXISTS dbscope_cap_tx_live');
    await executor().execute('CREATE TABLE dbscope_cap_tx_live (id int)');
    try {
      await executor().execute('BEGIN');
      await executor().execute('INSERT INTO dbscope_cap_tx_live VALUES (1)');
      final result = await QueryRunner(executor()).runSql(
        'SELECT g FROM generate_series(1, ${QueryRunner.maxRows + 5}) g',
      );
      expect(result.truncated, isTrue);
      expect(result.data.rows, hasLength(QueryRunner.maxRows));
      await executor().execute('COMMIT');
      final count = await executor().execute('SELECT count(*)::int FROM dbscope_cap_tx_live');
      expect(count.rows.first.first, 1);
    } finally {
      await executor().execute('DROP TABLE dbscope_cap_tx_live');
    }
  });

  test('an edit queued behind a capped read keeps its row', () async {
    await executor().execute('DROP TABLE IF EXISTS dbscope_cap_edit_live');
    await executor().execute('CREATE TABLE dbscope_cap_edit_live (id int)');
    try {
      // Queued together on the one connection, as two tabs' statements are.
      final read = executor().execute(_kEndless, rowCap: _kCap);
      final edit = executor().execute('INSERT INTO dbscope_cap_edit_live VALUES (1)');
      await Future.wait([read, edit]);
      final count = await executor().execute('SELECT count(*)::int FROM dbscope_cap_edit_live');
      expect(count.rows.first.first, 1);
    } finally {
      await executor().execute('DROP TABLE dbscope_cap_edit_live');
    }
  });

  test('a capped read binds its parameters', () async {
    final result = await executor().execute(
      r'SELECT generate_series(1, $1::int)',
      positional: [100],
      rowCap: _kCap,
    );
    expect(result.rows, hasLength(10));
    expect(result.truncated, isTrue);
    final named = await executor().execute(
      'SELECT generate_series(1, @n::int)',
      named: {'n': 5},
      rowCap: _kCap,
    );
    expect(named.rows, hasLength(5));
    expect(named.truncated, isFalse);
  });

  test('a capped read that fails leaves the connection usable', () async {
    await expectLater(
      executor().execute('SELECT 1/0', rowCap: _kCap),
      throwsA(anything),
    );
    expect((await executor().execute('SELECT 1')).rows.first.first, 1);
    final open = await executor().execute("SELECT current_setting('transaction_read_only')");
    expect(open.rows, hasLength(1));
  });

  test('cancelling a capped read works', () async {
    final token = CancelToken();
    final running = executor().execute(
      'SELECT pg_sleep(60)',
      cancelToken: token,
      rowCap: _kCap,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    token.cancel();
    expect((await running).rows, isEmpty);
    expect((await executor().execute('SELECT 1')).rows.first.first, 1);
  });

  test("a capped read can't commit another tab's open transaction", () async {
    await executor().execute('DROP TABLE IF EXISTS dbscope_cap_tx2_live');
    await executor().execute('CREATE TABLE dbscope_cap_tx2_live (id int)');
    await executor().execute('INSERT INTO dbscope_cap_tx2_live VALUES (1)');
    try {
      // Tab A opens a transaction while tab B's capped read is on the wire.
      final read = executor().execute(_kEndless, rowCap: _kCap);
      await executor().execute('BEGIN');
      await executor().execute('DELETE FROM dbscope_cap_tx2_live');
      await read;
      await QueryRunner(executor()).runSql(_kEndless);
      await executor().execute('ROLLBACK');
      final count = await executor().execute('SELECT count(*)::int FROM dbscope_cap_tx2_live');
      expect(count.rows.first.first, 1);
    } finally {
      await executor().execute('DROP TABLE dbscope_cap_tx2_live');
    }
  });

  test('wrapping a read keeps its comments, columns and clauses working', () async {
    Future<List<Object?>> first(String sql) async {
      final result = await executor().execute(sql, rowCap: _kCap);
      return result.rows.first;
    }

    expect(await first('SELECT 1 -- trailing comment'), [1]);
    expect(await first('SELECT 1 AS a, 2 AS a'), [1, 2]);
    expect(await first("SELECT 1, 'x'"), [1, 'x']);
    expect(await first('VALUES (7)'), [7]);
    expect(await first('WITH x AS (SELECT 2 AS n) SELECT n FROM x ORDER BY n'), [2]);
    expect(await first('SELECT g FROM generate_series(1, 3) g ORDER BY g DESC'), [3]);
    final duplicates = await executor().execute('SELECT 1 AS a, 2 AS a', rowCap: _kCap);
    expect(duplicates.columns.map((column) => column.name), ['a', 'a']);
    await executor().execute('DROP TABLE IF EXISTS dbscope_cap_wrap_live');
    await executor().execute('CREATE TABLE dbscope_cap_wrap_live AS SELECT 5 AS n');
    try {
      expect(await first('TABLE dbscope_cap_wrap_live'), [5]);
      expect(await first('SELECT n FROM dbscope_cap_wrap_live FOR UPDATE'), [5]);
    } finally {
      await executor().execute('DROP TABLE dbscope_cap_wrap_live');
    }
  });

  test('the query runner stops an endless read inside an open transaction', () async {
    await executor().execute('BEGIN');
    try {
      final result = await QueryRunner(executor()).runSql(_kEndless);
      expect(result.truncated, isTrue);
      expect(result.data.rows, hasLength(QueryRunner.maxRows));
      await executor().execute("SELECT set_config('dbscope.live_probe', 'x', true)");
      final stillOpen = await executor().execute("SELECT current_setting('dbscope.live_probe', true)");
      expect(stillOpen.rows.first.first, 'x');
    } finally {
      await executor().execute('ROLLBACK');
    }
  });

  test('the query runner stops an endless read outside a transaction', () async {
    final stopwatch = Stopwatch()..start();
    final result = await QueryRunner(executor()).runSql(_kEndless);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(result.truncated, isTrue);
    expect(result.data.rows, hasLength(QueryRunner.maxRows));
  });

  test('cancelling a queued statement leaves the one running before it alone', () async {
    final token = CancelToken();
    final first = executor().execute('SELECT pg_sleep(2), 7');
    final queued = executor().execute('SELECT 1', cancelToken: token);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    token.cancel();
    final firstResult = await first;
    expect(firstResult.rows.first.last, 7);
    await queued;
  });

  test('less common types read as Postgres text', () async {
    final result = await executor().execute(
      "SELECT '-12.05'::money, '::1'::inet, '2001:db8::1/64'::inet, "
      "'192.168.0.0/16'::cidr, '08:00:2b:01:02:03'::macaddr, "
      "'12:30:00+02'::timetz, B'10110'::bit(5), B'101'::varbit, "
      "'1 year 2 mons 3 days 04:05:06.5'::interval, '-01:00:00'::interval, "
      "ARRAY['a b', NULL]::text[]",
    );
    expect(result.rows.first, [
      '-12.05',
      '::1',
      '2001:db8::1/64',
      '192.168.0.0/16',
      '08:00:2b:01:02:03',
      '12:30:00+02',
      '10110',
      '101',
      '1 year 2 mons 3 days 04:05:06.5',
      '-01:00:00',
      '{"a b",NULL}',
    ]);
  });

  test('values read as Postgres text', () async {
    final result = await executor().execute(
      r"SELECT '1 day 02:00:00'::interval, '\xdead'::bytea, '12.50'::money, "
      "'10.0.0.1/8'::inet, ARRAY[1,2]::int4[], '12:30:00'::time",
    );
    expect(result.rows.first, [
      '1 day 02:00:00',
      r'\xdead',
      '12.50',
      '10.0.0.1/8',
      '{1,2}',
      '12:30:00',
    ]);
  });
}

void main() {
  final enabled = Platform.environment['DBSCOPE_LIVE_PG'] != null;
  final proxyUrl = Platform.environment['DBSCOPE_LIVE_PROXY_URL'];

  group('live: direct connection', skip: !enabled, () {
    PostgresExecutor? executor;
    setUpAll(() async {
      executor = PostgresExecutor(
        await PostgresKindPlugin.openConnection(
          host: _env('PGHOST', 'localhost'),
          port: int.parse(_env('PGPORT', '5432')),
          database: _env('PGDATABASE', 'postgres'),
          username: _env('PGUSER', 'postgres'),
          password: _env('PGPASSWORD', ''),
        ),
      );
    });
    tearDownAll(() => executor?.close());
    _sharedContract(() => executor!);

    test('a sorted no-PK table pages through tied rows without repeats', () async {
      final live = executor!;
      await live.execute('DROP TABLE IF EXISTS dbscope_tie_live');
      await live.execute('CREATE TABLE dbscope_tie_live (tag text, n int, doc json)');
      try {
        await live.execute(
          "INSERT INTO dbscope_tie_live SELECT 'same', g, '{}' FROM generate_series(1, 1000) g",
        );
        // A later UPDATE moves rows, which is what makes ties shuffle.
        await live.execute('UPDATE dbscope_tie_live SET n = n WHERE n % 3 = 0');
        final columns = await SchemaCatalog.unfiltered(live).listColumns('public', 'dbscope_tie_live');
        final pager = KeysetPager(
          conn: live,
          schema: 'public',
          table: 'dbscope_tie_live',
          columns: columns,
          pkColumns: const [],
          sortColumn: 'tag',
          pageSize: 100,
        );
        final seen = <Object?>[];
        while (!pager.isDone) {
          final page = await pager.fetchNext();
          seen.addAll(page.rows.map((row) => row[1]));
        }
        expect(seen, hasLength(1000));
        expect(seen.toSet(), hasLength(1000));
      } finally {
        await live.execute('DROP TABLE dbscope_tie_live');
      }
    });

    test('the copy job writes identity columns and leaves generated ones out', () async {
      final live = executor!;
      final target = PostgresExecutor(
        await PostgresKindPlugin.openConnection(
          host: _env('PGHOST', 'localhost'),
          port: int.parse(_env('PGPORT', '5432')),
          database: _env('PGDATABASE', 'postgres'),
          username: _env('PGUSER', 'postgres'),
          password: _env('PGPASSWORD', ''),
        ),
      );
      const table = '(id int GENERATED ALWAYS AS IDENTITY, v int, g int GENERATED ALWAYS AS (v * 2) STORED)';
      await live.execute('DROP TABLE IF EXISTS dbscope_copy_src, dbscope_copy_dst');
      await live.execute('CREATE TABLE dbscope_copy_src $table');
      await live.execute('CREATE TABLE dbscope_copy_dst $table');
      try {
        await live.execute('INSERT INTO dbscope_copy_src (v) VALUES (10), (20)');
        await live.raw.runTx((source) async {
          await CopyTableJob.copyRows(
            source: source,
            target: target.raw,
            qSource: '"public"."dbscope_copy_src"',
            qTarget: '"public"."dbscope_copy_dst"',
            columns: const ['id', 'v'],
            overridingSystemValue: true,
            isCancelled: () => false,
            onProgress: (_) {},
          );
        });
        final copied = await live.execute('SELECT id, v, g FROM dbscope_copy_dst ORDER BY id');
        expect(copied.rows, [
          [1, 10, 20],
          [2, 20, 40],
        ]);
      } finally {
        await live.execute('DROP TABLE dbscope_copy_src, dbscope_copy_dst');
        await target.close();
      }
    });

    test('a covering or partial index does not make a payload column indexed', () async {
      final live = executor!;
      await live.execute('DROP TABLE IF EXISTS dbscope_idx_live');
      await live.execute('CREATE TABLE dbscope_idx_live (k int, payload int, part int, whole int)');
      try {
        await live.execute('CREATE INDEX ON dbscope_idx_live (k) INCLUDE (payload)');
        await live.execute('CREATE INDEX ON dbscope_idx_live (part) WHERE part > 0');
        await live.execute('CREATE INDEX ON dbscope_idx_live (whole)');
        final indexed = await SchemaCatalog.unfiltered(live).indexedColumns('public', 'dbscope_idx_live');
        expect(indexed, containsAll(<String>['k', 'whole']));
        expect(indexed, isNot(contains('payload')));
        expect(indexed, isNot(contains('part')));
      } finally {
        await live.execute('DROP TABLE dbscope_idx_live');
      }
    });
  });

  group('live: through the web proxy', skip: !enabled || proxyUrl == null, () {
    DbExecutor? executor;
    setUpAll(() async {
      executor = await PgProxyExecutor.open(_proxyProfile(proxyUrl!));
    });
    tearDownAll(() => executor?.close());
    _sharedContract(() => executor!);

    // Timing-dependent: without the proxy's error zone, 12 rounds of this killed
    // it in 1 run of 4 when measured, so this uses more rounds. A pass is weak
    // evidence on its own; a failure is real.
    test('clients vanishing mid-statement do not take the proxy down', () async {
      for (var round = 0; round < 36; round++) {
        await Future.wait([
          for (var variant = 0; variant < 12; variant++) _dropClient(Uri.parse(proxyUrl!), variant + round),
        ]);
      }
      // A dead proxy refuses this.
      final other = await PgProxyExecutor.open(_proxyProfile(proxyUrl!));
      expect((await other.execute('SELECT 1')).rows.first.first, 1);
      await other.close();
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

ConnectionProfile _proxyProfile(String proxyUrl) => ConnectionProfile(
  id: 'live',
  name: 'live',
  host: _env('PGHOST', 'localhost'),
  port: int.parse(_env('PGPORT', '5432')),
  database: _env('PGDATABASE', 'postgres'),
  username: _env('PGUSER', 'postgres'),
  password: _env('PGPASSWORD', ''),
  extra: {'proxyUrl': proxyUrl},
);

/// A WebSocket client that sends work and disappears without closing, in the
/// way chosen by [variant]. `dart:io`'s WebSocket can't do that, so this speaks
/// the handshake and frames itself. Destroying a socket with unread data resets
/// it, as a lost network does.
Future<void> _dropClient(Uri proxy, int variant) async {
  const big = "SELECT generate_series(1, 90000), repeat('x', 200)";
  final socket = await Socket.connect(proxy.host, proxy.port);
  final upgraded = Completer<void>();
  void onUpgraded() {
    if (!upgraded.isCompleted) upgraded.complete();
  }

  // ignore: cancel_subscriptions, destroyed with the socket below.
  final reading = socket.listen((_) => onUpgraded(), onError: (Object _) {}, onDone: onUpgraded);
  socket.write(
    'GET / HTTP/1.1\r\nHost: ${proxy.host}\r\nUpgrade: websocket\r\n'
    'Connection: Upgrade\r\nSec-WebSocket-Key: ${base64Encode(List.filled(16, 7))}\r\n'
    'Sec-WebSocket-Version: 13\r\n\r\n',
  );
  await upgraded.future;
  void send(Map<String, Object?> message) {
    final payload = utf8.encode(jsonEncode(message));
    // Final text frame, masked as a client must, with a zero mask for brevity.
    socket.add([0x81, 0x80 | 126, payload.length >> 8, payload.length & 0xff, 0, 0, 0, 0, ...payload]);
  }

  send({
    'type': 'open',
    'host': _env('PGHOST', 'localhost'),
    'port': int.parse(_env('PGPORT', '5432')),
    'database': _env('PGDATABASE', 'postgres'),
    'username': _env('PGUSER', 'postgres'),
    'password': _env('PGPASSWORD', ''),
    'sslMode': 'disable',
  });
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final waitMilliseconds = 20 * (variant % 25);
  switch (variant % 4) {
    case 0:
      // Stop reading, so closing leaves data unread.
      reading.pause();
      send({'type': 'execute', 'id': 'a', 'sql': big});
    case 1:
      send({'type': 'execute', 'id': 'a', 'sql': big});
      send({'type': 'close'});
      reading.pause();
    case 2:
      for (var i = 0; i < 5; i++) {
        send({'type': 'execute', 'id': 'q$i', 'sql': 'SELECT pg_sleep(0.2), generate_series(1, 20000)'});
      }
      send({'type': 'cancel', 'id': 'q0'});
      reading.pause();
    case 3:
      send({'type': 'execute', 'id': 'a', 'sql': big});
  }
  await Future<void>.delayed(Duration(milliseconds: waitMilliseconds));
  socket.destroy();
}
