import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/plugin.dart';
import 'package:dbscope/plugins/dbscope_plugin.dart';
import 'package:flutter/material.dart';

import 'executor.dart';
import 'profile_dialog.dart';

const String kPgProxyKind = 'pg_proxy';

class PgProxyKindPlugin implements ConnectionKindPlugin {
  const PgProxyKindPlugin();

  @override
  String get id => kPgProxyKind;

  @override
  String get label => 'PostgreSQL (via proxy)';

  @override
  Future<OpenResult> open(
    ConnectionProfile profile, {
    BuildContext? context,
  }) async {
    final exec = await PgProxyExecutor.open(profile);
    return OpenResult(executor: exec);
  }

  @override
  Future<ConnectionProfile?> showProfileDialog(
    BuildContext context, {
    ConnectionProfile? initial,
  }) {
    return showPgProxyDialog(context, initial: initial);
  }
}

/// Universal-plugin wrapper. main.dart calls
/// `DbscopePluginRegistry.instance.register(PgProxyPlugin())` once
/// during startup; [register] wires the kind into the connection
/// registry.
class PgProxyPlugin extends DbscopePlugin {
  @override
  String get id => 'pg-proxy';
  @override
  String get label => 'Postgres via proxy';

  @override
  void register(DbscopeHost host) {
    host.connections.register(const PgProxyKindPlugin());
  }
}
