import '../postgres_executor.dart';
import 'cloudsql_config.dart';
import 'cloudsql_proxy_manager.dart';

/// A Postgres executor that speaks to a Cloud SQL instance through a local
/// Auth Proxy tunnel. It behaves exactly like [PostgresExecutor] (so
/// pg-specific call sites — e.g. `CopyTableJob`'s `is PostgresExecutor`
/// downcast — keep working) but releases the proxy reference when closed, so
/// the tunnel is torn down once no executor needs it.
class CloudSqlExecutor extends PostgresExecutor {
  final CloudSqlConfig _config;
  bool _released = false;

  CloudSqlExecutor(super.conn, this._config);

  @override
  Future<void> close({bool force = false}) async {
    await super.close(force: force);
    await _releaseProxy();
  }

  Future<void> _releaseProxy() async {
    if (_released) return;
    _released = true;
    await CloudSqlProxyManager.instance.release(_config);
  }
}
