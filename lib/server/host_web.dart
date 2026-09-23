// Web HostBackend. Identical to the desktop variant except for two
// deliberate omissions:
// - no CopyTableJob (postgres-only; pulls in package:postgres which
// uses dart:io Socket and doesn't compile on web)
// - no IsolateTransport wiring at the consumer; web is single-window
// The LocalTransport-backed BackendClient still drives the same UI
// against whatever backend kinds are registered on web.

import '../rpc/backend_client.dart';
import '../rpc/transport.dart';
import 'server.dart';
import 'services/bus_service.dart';
import 'services/connection_service.dart';
import 'services/job_service.dart';
import 'services/profile_service.dart';

class HostBackend {
  final Server server;
  final BusService bus;
  final ProfileService profiles;
  final ConnectionService connections;
  final JobService jobs;
  late final BackendClient localClient;
  late final LocalTransport _localTransport;

  HostBackend._({
    required this.server,
    required this.bus,
    required this.profiles,
    required this.connections,
    required this.jobs,
  }) {
    _localTransport = LocalTransport((env, reply) {
      server.dispatch(env, reply);
    });
    localClient = BackendClient(_localTransport);
  }

  factory HostBackend.create() {
    final server = Server();
    final bus = BusService();
    final profiles = ProfileService(bus: bus);
    final connections = ConnectionService(profiles: profiles, bus: bus);
    final jobs = JobService(connections: connections, bus: bus);
    // CopyTableJob omitted intentionally on web — see file header.
    bus.register(server);
    profiles.register(server);
    connections.register(server);
    jobs.register(server);
    return HostBackend._(
      server: server,
      bus: bus,
      profiles: profiles,
      connections: connections,
      jobs: jobs,
    );
  }

  Future<void> dispose() async {
    await connections.closeAll();
    await localClient.dispose();
    await bus.dispose();
    await server.dispose();
  }
}
