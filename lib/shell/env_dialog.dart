import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../util/shell_env.dart';
import 'ui_prefs.dart';

/// Picks the shell env file dbscope reads variables from.
///
/// The whole feature exists because a GUI-launched app can't see the
/// user's shell exports — see [ShellEnv]. This dialog is where that
/// becomes visible: it names the file, says whether it was read, and
/// lists the variable names it found so "why isn't my key working"
/// has an answer on screen instead of in a debugger.
///
/// Values are never shown. They are API keys and passphrases, and a
/// screenshot of this dialog should be safe to paste in a bug report.
class EnvDialog extends StatefulWidget {
  const EnvDialog({super.key});

  @override
  State<EnvDialog> createState() => _EnvDialogState();
}

class _EnvDialogState extends State<EnvDialog> {
  final TextEditingController _pathController = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pathController.text = UiPrefs.instance.envFilePath ?? '';
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  /// Loads the typed path so the status line answers for the file the
  /// user is about to save, not the one already saved.
  Future<void> _check() async {
    setState(() => _busy = true);
    await ShellEnv.instance.load(path: _pathController.text);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _browse() async {
    final file = await openFile();
    if (file == null) return;
    _pathController.text = file.path;
    await _check();
  }

  Future<void> _useDefault() async {
    _pathController.clear();
    await _check();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final path = _pathController.text.trim();
    UiPrefs.instance.setEnvFilePath(path);
    await ShellEnv.instance.load(path: path);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Puts the global back on the saved path — [_check] and [_browse]
  /// load speculatively, and an abandoned dialog must not leave the app
  /// reading a file the user decided against.
  Future<void> _cancel() async {
    await ShellEnv.instance.load(path: UiPrefs.instance.envFilePath);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!ShellEnv.isSupported) {
      return AlertDialog(
        title: const Text('Environment'),
        content: const Text(
          'There is no shell environment in a browser. Paste keys '
          'directly into AI ▸ Settings… instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final defaultPath = ShellEnv.defaultPath ?? '(none on this platform)';
    // `_check` / `_browse` / `_useDefault` load the global speculatively so
    // the status line answers for the file about to be saved, and `_cancel`
    // is what puts it back. Escape and the barrier pop WITHOUT reaching
    // Cancel, which would leave the whole app reading a file the user backed
    // out of until the next launch — so every exit is routed through it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      child: _buildDialog(defaultPath),
    );
  }

  Widget _buildDialog(String defaultPath) {
    return AlertDialog(
      title: const Text('Environment'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Launched from Finder, dbscope never sees the variables '
                'your shell exports. It reads them from this file '
                'instead — API keys like GEMINI_API_KEY, the connection-'
                'link passphrase, and the PATH used to find '
                'cloud-sql-proxy.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pathController,
                decoration: InputDecoration(
                  labelText: 'Env file',
                  isDense: true,
                  hintText: defaultPath,
                  helperText: 'Empty means $defaultPath.',
                ),
                onSubmitted: (_) => _check(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy ? null : _useDefault,
                    child: const Text('Use default'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _busy ? null : _browse,
                    child: const Text('Browse…'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _busy ? null : _check,
                    child: const Text('Reload'),
                  ),
                ],
              ),
              const Divider(height: 24),
              _EnvStatus(env: ShellEnv.instance),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _cancel,
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Outcome of the last load: where it read, and which names it found.
class _EnvStatus extends StatelessWidget {
  final ShellEnv env;
  const _EnvStatus({required this.env});

  @override
  Widget build(BuildContext context) {
    final names = env.names;
    final (String message, Color color) = switch (env.status) {
      ShellEnvStatus.loaded => (
        '${names.length} variable(s) read from ${env.resolvedPath}',
        Colors.green,
      ),
      ShellEnvStatus.missing => (
        'No file at ${env.resolvedPath}',
        Colors.orange,
      ),
      ShellEnvStatus.unreadable => (
        'Could not read ${env.resolvedPath}: ${env.error}',
        Colors.red,
      ),
      ShellEnvStatus.unsupported => (
        'No default env file on this platform — set one above.',
        Colors.orange,
      ),
      ShellEnvStatus.notLoaded => ('Not loaded yet.', Colors.grey),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message, style: TextStyle(fontSize: 12, color: color)),
        if (names.isNotEmpty) ...[
          const SizedBox(height: 8),
          // Names only — the values are secrets.
          SelectableText(
            names.join(', '),
            style: const TextStyle(fontSize: 11, height: 1.5),
          ),
        ],
      ],
    );
  }
}

Future<void> showEnvDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const EnvDialog(),
  );
}
