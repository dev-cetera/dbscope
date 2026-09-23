// Bundle of connection-kind plugins shipped on web. Postgres and local
// SQLite need native code that doesn't exist in a browser, so they're
// absent here by design. Pg-proxy is always available (real Postgres
// via the WebSocket bridge).

import 'package:dbscope_pg_proxy_plugin/dbscope_pg_proxy_plugin.dart';

import 'dbscope_plugin.dart';

List<DbscopePlugin> platformConnectionPlugins() => [PgProxyPlugin()];
