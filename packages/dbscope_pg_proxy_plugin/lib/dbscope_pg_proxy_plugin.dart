// PgProxy connection-kind plugin for DBScope. Targets a
// dbscope_pg_proxy server (see packages/dbscope_pg_proxy/) over
// WebSocket; works on web, where raw TCP to Postgres is impossible, and
// also on native if a centralised proxy is preferable to direct TCP.
//
// Usage: register the plugin once during app startup —
//
// DbscopePluginRegistry.instance.register(PgProxyPlugin());

export 'src/plugin.dart' show PgProxyPlugin, PgProxyKindPlugin;
