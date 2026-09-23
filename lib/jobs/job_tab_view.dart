import 'dart:async';

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../../rpc/scope.dart';
import '../../rpc/services/bus_client.dart';
import '../../rpc/services/job_client.dart';
import '../shell/app_state.dart';

class JobTabView extends StatefulWidget {
  final JobTab tab;
  const JobTabView({super.key, required this.tab});

  @override
  State<JobTabView> createState() => _JobTabViewState();
}

class _JobTabViewState extends State<JobTabView> {
  StreamSubscription<BusEvent>? _progressSub;
  StreamSubscription<BusEvent>? _finishedSub;

  @override
  void initState() {
    super.initState();
    final client = BackendScope.of(context);
    final bus = BusClient(client);
    _progressSub = bus
        .subscribe('job.progress:${widget.tab.jobId}')
        .listen(_onProgress);
    _finishedSub = bus
        .subscribe('job.finished:${widget.tab.jobId}')
        .listen(_onFinished);
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _finishedSub?.cancel();
    super.dispose();
  }

  void _onProgress(BusEvent e) {
    final map = e.dataAsMap;
    if (map == null) return;
    setState(() {
      widget.tab.phase = (map['phase'] as String?) ?? widget.tab.phase;
      final processed = map['processed'];
      if (processed is num) widget.tab.processed = processed.toInt();
      final total = map['total'];
      if (total is num) widget.tab.total = total.toInt();
    });
    AppState.instance.notifyChange();
  }

  void _onFinished(BusEvent e) {
    final map = e.dataAsMap;
    if (map == null) return;
    setState(() {
      widget.tab.finished = true;
      widget.tab.phase = (map['state'] as String?) ?? 'completed';
      widget.tab.error = map['error'] as String?;
      final summary = map['summary'];
      if (summary is Map<String, Object?>) {
        final processed = summary['processed'];
        if (processed is num) widget.tab.processed = processed.toInt();
      }
    });
    AppState.instance.notifyChange();
  }

  Future<void> _cancel() async {
    final client = BackendScope.of(context);
    final jobs = JobServiceClient(client);
    try {
      await jobs.cancel(widget.tab.jobId);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tab = widget.tab;
    return AppPanel(
      title: tab.title,
      titleIcon: Icons.dynamic_form,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row('Job id', tab.jobId),
            _row('Kind', tab.kind),
            _row('Phase', tab.phase),
            _row('Processed', tab.processed.toString()),
            if (tab.total != null) _row('Total', tab.total.toString()),
            if (tab.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tab.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            if (!tab.finished)
              FilledButton.icon(
                icon: const Icon(Icons.cancel_outlined, size: 16),
                onPressed: _cancel,
                label: const Text('Cancel'),
              )
            else
              Text(
                tab.error == null ? 'Done.' : 'Stopped.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
