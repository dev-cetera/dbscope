import '../../tabs/tab_model.dart';

/// A background server-side job (e.g. CopyTableJob) surfaced as a tab
/// so the user can watch progress without losing their place. JobTabs
/// don't belong to any connection — `connectionId` is empty.
class JobTab extends TabModel {
  final String jobId;
  final String kind;
  String summary;
  String phase;
  int processed;
  int? total;
  bool finished;
  String? error;

  JobTab({
    super.id,
    required this.jobId,
    required this.kind,
    required this.summary,
    this.phase = 'queued',
    this.processed = 0,
    this.total,
    this.finished = false,
    this.error,
  }) : super(connectionId: '');

  @override
  String get title => 'Job: $summary';
}
