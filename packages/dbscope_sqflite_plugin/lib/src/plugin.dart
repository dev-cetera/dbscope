import 'package:flutter/material.dart';
import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/plugin.dart';
import 'package:dbscope/plugins/dbscope_plugin.dart';

import 'device_picker.dart';
import 'executor.dart';
import 'profile_dialog.dart';

/// Profile-kind id persisted to disk for this plugin. The id is unchanged
/// from the original VM-service implementation so existing profiles still
/// resolve, but they need to be re-saved through the new dialog (the
/// `extra` shape changed).
const String kSqfliteRemoteKind = 'sqflite_remote';

class SqfliteRemoteKindPlugin implements ConnectionKindPlugin {
  const SqfliteRemoteKindPlugin();

  @override
  String get id => kSqfliteRemoteKind;

  @override
  String get label => 'SQLite on connected device';

  @override
  Future<OpenResult> open(
    ConnectionProfile profile, {
    BuildContext? context,
  }) async {
    final deviceKind = (profile.extra['deviceKind'] as String?)?.trim() ?? '';
    final deviceId = (profile.extra['deviceId'] as String?)?.trim() ?? '';
    final appId = (profile.extra['appId'] as String?)?.trim() ?? '';
    final dbPath = (profile.extra['dbPath'] as String?)?.trim() ?? '';
    final deviceLabel =
        (profile.extra['deviceLabel'] as String?)?.trim() ?? deviceId;
    if (deviceKind.isEmpty ||
        deviceId.isEmpty ||
        appId.isEmpty ||
        dbPath.isEmpty) {
      throw StateError(
        'Device-SQLite profile is missing fields (was it saved with the '
        'old VM-service plugin? Re-add the connection).',
      );
    }
    final backend = buildBackend(
      DiscoveredDevice(kind: deviceKind, id: deviceId, label: deviceLabel),
      appId,
    );
    final executor = await DeviceSqliteExecutor.open(
      backend: backend,
      remoteDbPath: dbPath,
    );
    return OpenResult(executor: executor);
  }

  @override
  Future<ConnectionProfile?> showProfileDialog(
    BuildContext context, {
    ConnectionProfile? initial,
  }) {
    return showSqfliteRemoteDialog(context, initial: initial);
  }
}

/// Universal-plugin wrapper. main.dart calls
/// `DbscopePluginRegistry.instance.register(SqfliteRemotePlugin())`
/// once during startup; [register] wires the kind into the connection
/// registry.
class SqfliteRemotePlugin extends DbscopePlugin {
  @override
  String get id => 'sqflite-remote';
  @override
  String get label => 'On-device SQLite';

  @override
  void register(DbscopeHost host) {
    host.connections.register(const SqfliteRemoteKindPlugin());
  }
}
