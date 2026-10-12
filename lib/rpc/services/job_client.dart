// JobServiceClient — typed wrapper for job.* methods.

import '../backend_client.dart';

class JobSubmitResult {
  JobSubmitResult({required this.id, required this.raw});
  final String id;
  final Map<String, Object?> raw;
}

class JobServiceClient {
  JobServiceClient(this._client);
  final BackendClient _client;

  Future<JobSubmitResult> submit(
    String kind,
    Map<String, Object?> params,
  ) async {
    final result = await _client.request('job.submit', {
      'kind': kind,
      'params': params,
    });
    final map = result! as Map<String, Object?>;
    return JobSubmitResult(id: map['id']! as String, raw: map);
  }

  Future<void> cancel(String id) async {
    await _client.request('job.cancel', {'id': id});
  }

  Future<Map<String, Object?>> get(String id) async {
    final result = await _client.request('job.get', {'id': id});
    return result! as Map<String, Object?>;
  }
}
