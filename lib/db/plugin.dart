// Connection-kind plugin surface.
//
// Each "kind" of database connection (postgres, an external HTTP-mediated
// API, etc.) is a plugin that owns:
// - a kind id ('postgres', 'sqlite', ...) — the string serialised in
// ConnectionProfile.kind on disk
// - a label for the UI
// - a factory that opens a DbExecutor from a profile
// - a connection-dialog builder used when the user adds a profile of
// this kind
//
// The host wires the postgres kind itself. External kinds live in
// sibling Dart packages and call `ConnectionKindRegistry.instance.register`
// from their own `register()` entry point. The core never imports a plugin
// by name — removing a plugin means deleting its package + its single
// `register()` call from main.dart.

import 'package:flutter/widgets.dart';

import '../connection/profile.dart';
import 'executor.dart';

/// Result of opening a connection through a plugin: the executor plus any
/// updates the plugin made to the profile (e.g. a plugin may have learned
/// a refresh token during login and wants it persisted).
class OpenResult {
  final DbExecutor executor;
  final ConnectionProfile? updatedProfile;
  const OpenResult({required this.executor, this.updatedProfile});
}

abstract class ConnectionKindPlugin {
  String get id;
  String get label;

  /// Open a connection for [profile]. May prompt the user (e.g. for a
  /// TOTP code); [context] is the active BuildContext if a UI prompt is
  /// needed. Plugins that never need UI can ignore [context].
  Future<OpenResult> open(ConnectionProfile profile, {BuildContext? context});

  /// Show the "new connection" or "edit connection" dialog for this kind.
  /// Returns the entered profile or null if the user cancelled.
  Future<ConnectionProfile?> showProfileDialog(
    BuildContext context, {
    ConnectionProfile? initial,
  });
}

/// Process-wide registry. The host registers the built-in postgres kind
/// during main(); external packages register their kinds from main() too.
class ConnectionKindRegistry {
  ConnectionKindRegistry._();
  static final ConnectionKindRegistry instance = ConnectionKindRegistry._();

  final Map<String, ConnectionKindPlugin> _kinds = {};

  void register(ConnectionKindPlugin plugin) {
    _kinds[plugin.id] = plugin;
  }

  ConnectionKindPlugin? lookup(String id) => _kinds[id];

  List<ConnectionKindPlugin> get all => List.unmodifiable(_kinds.values);

  ConnectionKindPlugin require(String id) {
    final p = _kinds[id];
    if (p == null) {
      throw StateError('No connection kind plugin registered for "$id"');
    }
    return p;
  }
}
