import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../connection/registry.dart';
import '../util/pg_errors.dart';
import 'dbml_cache.dart';
import 'dbml_export.dart';
import 'dbml_save.dart';

class DbmlExportFlow {
  static Future<void> run(BuildContext context) async {
    final registry = ConnectionRegistry.instance;
    final conn = registry.connection;
    final profile = registry.profile;
    final messenger = ScaffoldMessenger.of(context);
    if (conn == null || profile == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Connect to a database first.')),
      );
      return;
    }

    final safeName = _safeProjectName(profile.database);

    String dbml;
    // Fast path: the registry warms DBML in the background on connect.
    // If it's ready, skip the progress dialog entirely.
    final cached = DbmlCache.instance.peek(profile.id);
    if (cached != null) {
      dbml = cached;
    } else {
      final progress = ValueNotifier<DbmlExportProgress?>(null);
      final dialogFuture = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ProgressDialog(progress: progress),
      );
      try {
        // The cache may have a pending future already; if so, await it.
        // Otherwise generate fresh and seed the cache via get() so a
        // subsequent invocation hits the fast path.
        dbml = await DbmlCache.instance.get(
          profile.id,
          conn,
          databaseName: safeName,
        );
      } catch (e) {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        await dialogFuture;
        messenger.showSnackBar(
          SnackBar(content: Text('Export failed: ${classify(e).message}')),
        );
        return;
      }
      if (context.mounted &&
          Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await dialogFuture;
      // Suppress the unused-progress warning when the cache wins.
      progress.dispose();
    }

    if (!context.mounted) return;
    final action = await showDialog<_PostExportAction>(
      context: context,
      builder: (_) => const _PostExportDialog(),
    );
    if (action == null) return;

    switch (action) {
      case _PostExportAction.saveToFile:
        await _saveToFile(messenger, dbml, profile.database);
        break;
      case _PostExportAction.copyToClipboard:
        await Clipboard.setData(ClipboardData(text: dbml));
        messenger.showSnackBar(
          const SnackBar(
            content: Text('DBML copied to clipboard.'),
          ),
        );
        break;
      case _PostExportAction.viewInBrowser:
        await Clipboard.setData(ClipboardData(text: dbml));
        await _openUrl('https://dbdiagram.io/d');
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'DBML copied. Paste it into the dbdiagram.io editor.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
        break;
    }
  }

  static Future<void> _saveToFile(
    ScaffoldMessengerState messenger,
    String dbml,
    String suggestedBase,
  ) async {
    if (kIsWeb) {
      // No file pickers in the browser shell; copy and tell the user.
      await Clipboard.setData(ClipboardData(text: dbml));
      messenger.showSnackBar(
        const SnackBar(content: Text('Saved to clipboard.')),
      );
      return;
    }
    final location = await getSaveLocation(
      suggestedName: '$suggestedBase.dbml',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'DBML', extensions: ['dbml']),
      ],
    );
    if (location == null) return;
    try {
      await writeDbmlFile(location.path, dbml);
      messenger.showSnackBar(
        SnackBar(content: Text('Saved ${location.path}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  static Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static String _safeProjectName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    if (cleaned.isEmpty || RegExp(r'^[0-9]').hasMatch(cleaned)) {
      return 'db_$cleaned';
    }
    return cleaned;
  }
}

enum _PostExportAction { saveToFile, copyToClipboard, viewInBrowser }

class _PostExportDialog extends StatelessWidget {
  const _PostExportDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('DBML ready'),
      content: const Text(
        'How do you want to use the DBML?',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_PostExportAction.copyToClipboard),
          child: const Text('Copy to clipboard'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_PostExportAction.viewInBrowser),
          child: const Text('View on dbdiagram.io'),
        ),
        if (!kIsWeb)
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_PostExportAction.saveToFile),
            child: const Text('Save to file…'),
          ),
      ],
    );
  }
}

class _ProgressDialog extends StatelessWidget {
  final ValueNotifier<DbmlExportProgress?> progress;
  const _ProgressDialog({required this.progress});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exporting DBML…'),
      content: ValueListenableBuilder<DbmlExportProgress?>(
        valueListenable: progress,
        builder: (context, p, _) {
          if (p == null) {
            return const SizedBox(
              width: 280,
              height: 56,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final value = p.total == 0 ? null : p.completed / p.total;
          return SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: value),
                const SizedBox(height: 8),
                Text(
                  p.currentTable.isEmpty
                      ? '${p.completed}/${p.total} tables'
                      : '${p.completed}/${p.total} ${p.currentTable}',
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
