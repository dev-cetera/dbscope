import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update/update_source.dart';

/// Whether the welcome dialog opens by itself at startup.
///
/// It is for someone who has never used dbscope, so it stays away from
/// anyone who clearly has: it was dismissed before, connections are
/// already saved, or a command-line launch is connecting on its own.
/// [seen] is null when preferences can't be read (a private browser
/// window); that counts as "not seen", because the only cost is showing
/// a dismissible dialog again to someone with no saved connections.
bool shouldShowWelcome({
  required bool? seen,
  required bool hasSavedProfiles,
  required bool autoConnecting,
}) {
  if (seen == true) return false;
  if (hasSavedProfiles) return false;
  if (autoConnecting) return false;
  return true;
}

/// What the user picked to leave the welcome dialog.
enum WelcomeChoice {
  /// Open the new-connection flow.
  addConnection,

  /// Just close the dialog.
  close,
}

/// The first thing a new user sees: what dbscope is, how to connect,
/// and what to try once connected.
///
/// Returns null when dismissed with Escape or the barrier, which the
/// caller treats the same as [WelcomeChoice.close].
Future<WelcomeChoice?> showWelcomeDialog(BuildContext context) {
  return showDialog<WelcomeChoice>(
    context: context,
    builder: (_) => const WelcomeDialog(),
  );
}

class WelcomeDialog extends StatelessWidget {
  const WelcomeDialog({super.key});

  static final Uri _proxyGuide = Uri.parse(
    'https://github.com/${ReleaseSource.owner}/${ReleaseSource.repo}'
    '/tree/main/packages/dbscope_pg_proxy#readme',
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.75);
    return AlertDialog(
      title: Column(
        children: [
          ClipRRect(
            // Matches the rounded corners baked into the icon (rx 230/1024).
            borderRadius: BorderRadius.circular(16.0),
            child: Image.asset(
              'assets/icon/dbscope_icon.png',
              width: 72.0,
              height: 72.0,
              cacheWidth: 216,
              semanticLabel: 'dbscope logo',
            ),
          ),
          const SizedBox(height: 14.0),
          const Text('Welcome to dbscope', textAlign: TextAlign.center),
        ],
      ),
      content: SizedBox(
        width: 500.0,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Browse, edit and query your databases, with an AI '
                'assistant that writes the SQL for you. Nothing is open '
                'yet, so here is how to get started.',
              ),
              const SizedBox(height: 18.0),
              const _Step(
                number: 1,
                title: 'Connect to a database',
                body: kIsWeb
                    ? 'A browser can’t talk to Postgres directly, so the web '
                          'version connects through dbscope_pg_proxy, a small '
                          'proxy you run next to your database. Start it, then '
                          'choose Add a connection and enter its address '
                          '(for example ws://127.0.0.1:8765).'
                    : 'Choose Add a connection for Postgres, Cloud SQL, or '
                          'SQLite inside an app on a USB-connected phone. To '
                          'open a local SQLite file, use File ▸ Open .db file….',
              ),
              const _Step(
                number: 2,
                title: 'Explore your tables',
                body:
                    'Tables appear in the sidebar. Click one to open it in '
                    'a tab, and double-click a cell to edit it. View ▸ '
                    'Schema draws every table and how they relate.',
              ),
              const _Step(
                number: 3,
                title: 'Ask questions',
                body:
                    'File ▸ New query opens a SQL editor. AI ▸ New AI query '
                    'lets you describe what you want in plain English; add '
                    'an API key under AI ▸ Settings… first.',
              ),
              if (kIsWeb) ...[
                const SizedBox(height: 4.0),
                Wrap(
                  spacing: 8.0,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.menu_book_outlined, size: 16.0),
                      label: const Text('How to run the proxy'),
                      onPressed: () => unawaited(launchUrl(_proxyGuide)),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.laptop_mac_outlined, size: 16.0),
                      label: const Text('Get the Mac app'),
                      onPressed: () => unawaited(launchUrl(ReleaseSource.releasesPage)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8.0),
              Text(
                'You can open this again from Help ▸ Welcome….',
                style: TextStyle(fontSize: 12.0, color: muted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(WelcomeChoice.close),
          child: const Text('Not now'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(WelcomeChoice.addConnection),
          child: const Text('Add a connection…'),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.title, required this.body});

  final int number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24.0,
            height: 24.0,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
            child: Text(
              '$number',
              style: TextStyle(
                color: scheme.onPrimary,
                fontSize: 12.0,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12.0),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2.0),
                Text(body),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
