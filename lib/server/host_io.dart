// Host — constructs the Server, registers services, and exposes a
// BackendClient for in-process callers. In multi-window mode, this same
// Server also accepts envelopes from subwindows via IsolateTransport.

import '../rpc/backend_client.dart';
import '../rpc/transport.dart';
import 'jobs/copy_table_job.dart';
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
    jobs.registerHandler(CopyTableJob());
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
