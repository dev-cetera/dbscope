import 'package:flutter/material.dart';
import 'package:key_flow/key_flow.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util/error_reporting.dart';
import 'command_registry.dart';

/// File ▸ Show crash log: opens the folder `installErrorHandlers` writes to,
/// so a user can attach `dbscope.log` to a bug report. Desktop only; the web
/// build logs to the browser console instead.
final crashLogCommandContribution = CommandContribution(
  menu: AppMenu.file.label,
  build: () => [
    KeyCommand(
      id: 'show_crash_log',
      label: 'Show crash log',
      onRun: (_) => _showCrashLog(appContext()),
    ),
  ],
);

Future<void> _showCrashLog(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final folder = crashLogFolder();
  final opened = folder != null && await launchUrl(Uri.directory(folder));
  if (!opened) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Could not open ${folder ?? 'the crash log folder'}.')),
    );
  }
}
