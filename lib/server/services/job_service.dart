// JobService — submit, list, cancel jobs. Jobs run on the server in this
// isolate, using ConnectionService for DB access. Lifecycle events are
// published on the bus so any window can subscribe.

import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../rpc/envelope.dart';
import '../jobs/job.dart';
import '../server.dart';
import 'bus_service.dart';
import 'connection_service.dart';

class JobService {
  final ConnectionService _connections;
  final BusService _bus;
  final Map<String, JobHandler> _handlers = {};
  final Map<String, JobRecord> _jobs = {};
  final Map<String, JobContext> _contexts = {};

  JobService({required ConnectionService connections, required BusService bus})
    : _connections = connections,
      _bus = bus;

  void registerHandler(JobHandler handler) {
    _handlers[handler.kind] = handler;
  }

  void register(Server server) {
    server.onRequest('job.submit', _submit);
    server.onRequest('job.list', (_) async => _listJson());
    server.onRequest('job.get', (p) async {
      _ensureMap(p);
      final id = (p as Map<String, Object?>)['id'] as String?;
      if (id == null) {
        throw const RpcError('bad_params', 'id required');
      }
      final job = _jobs[id];
      if (job == null) throw RpcError('not_found', 'job $id');
      return job.toJson();
    });
    server.onRequest('job.cancel', (p) async {
      _ensureMap(p);
      final id = (p as Map<String, Object?>)['id'] as String?;
      if (id == null) {
        throw const RpcError('bad_params', 'id required');
      }
      _contexts[id]?.cancel();
      return null;
    });
  }

  Future<Object?> _submit(Object? params) async {
    _ensureMap(params);
    final p = params as Map<String, Object?>;
    final spec = JobSpec.fromJson(p);
    final handler = _handlers[spec.kind];
    if (handler == null) {
      throw RpcError('unknown_job', 'no handler for ${spec.kind}');
    }
    final id = const Uuid().v4();
    final record = JobRecord(id: id, spec: spec);
    _jobs[id] = record;
    final ctx = JobContext(
      record: record,
      connections: _connections,
      bus: _bus,
    );
    _contexts[id] = ctx;
    _publish('job.created', record);
    // Fire and forget — caller gets the id back, observes via bus.
    unawaited(_run(handler, ctx));
    return record.toJson();
  }

  Future<void> _run(JobHandler handler, JobContext ctx) async {
    final record = ctx.record;
    record.state = JobState.running;
    _publish('job.started:${record.id}', record);
    try {
      final summary = await handler.run(ctx);
      record.summary = summary;
      record.state = ctx.cancelled ? JobState.cancelled : JobState.completed;
    } on RpcError catch (e) {
      record.error = e.message;
      record.state = JobState.failed;
    } catch (e) {
      record.error = e.toString();
      record.state = JobState.failed;
    } finally {
      record.finishedAt = DateTime.now();
      _contexts.remove(record.id);
      _publish('job.finished:${record.id}', record);
    }
  }

  List<Object?> _listJson() => [for (final r in _jobs.values) r.toJson()];

  void _publish(String topic, JobRecord record) {
    _bus.publish(topic, record.toJson());
  }

  void _ensureMap(Object? p) {
    if (p is! Map<String, Object?>) {
      throw const RpcError('bad_params', 'expected object');
    }
  }
}
