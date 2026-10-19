// Job model + execution context. Jobs run on the server, own their own
// connections via ConnectionService, and publish progress through the
// bus.

import 'dart:async';

import '../services/bus_service.dart';
import '../services/connection_service.dart';

enum JobState { queued, running, completed, failed, cancelled }

class JobSpec {
  const JobSpec({required this.kind, required this.params});

  factory JobSpec.fromJson(Map<String, Object?> json) => JobSpec(
    kind: json['kind']! as String,
    params: (json['params'] as Map<String, Object?>?) ?? const {},
  );

  final String kind; // wire type tag, e.g. 'copy_table'
  final Map<String, Object?> params;

  Map<String, Object?> toJson() => {'kind': kind, 'params': params};
}

class JobRecord {
  JobRecord({required this.id, required this.spec}) : createdAt = DateTime.now();
  final String id;
  final JobSpec spec;
  JobState state = JobState.queued;
  String? error;
  // Free-form summary populated by the job (rows copied, etc.).
  Map<String, Object?> summary = const {};
  final DateTime createdAt;
  DateTime? finishedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'spec': spec.toJson(),
    'state': state.name,
    if (error != null) 'error': error,
    'summary': summary,
    'createdAt': createdAt.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
  };
}

abstract class JobHandler {
  String get kind;
  Future<Map<String, Object?>> run(JobContext jobContext);
}

class JobContext {
  JobContext({
    required this.record,
    required this.connections,
    required this.bus,
  });
  final JobRecord record;
  final ConnectionService connections;
  final BusService bus;
  var _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void reportProgress(Map<String, Object?> data) {
    bus.publish('job.progress:${record.id}', data);
  }
}
