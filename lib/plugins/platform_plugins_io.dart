// Bundle of connection-kind plugins shipped on platforms that have
// dart:io: the built-in Postgres + SQLite kinds plus the external
// connection plugins (on-device SQLite over adb/devicectl, pg-proxy
// WebSocket).
//
// main.dart hands every entry to `DbscopePluginRegistry.register`, so
// removing a plugin is one line in this file plus the matching pubspec
// dependency drop.

import 'package:dbscope_pg_proxy_plugin/dbscope_pg_proxy_plugin.dart';
import 'package:dbscope_sqflite_plugin/dbscope_sqflite_plugin.dart';

import '../db/cloudsql/cloudsql_plugin.dart';
import '../db/postgres_plugin.dart';
import '../db/sqlite_plugin.dart';
import 'dbscope_plugin.dart';

List<DbscopePlugin> platformConnectionPlugins() => [
  PostgresPlugin(),
  SqlitePlugin(),
  CloudSqlPlugin(),
  SqfliteRemotePlugin(),
  PgProxyPlugin(),
];
