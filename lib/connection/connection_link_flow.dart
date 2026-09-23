import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../util/portable_io.dart';
import 'connection_link.dart';
import 'profile.dart';
import 'registry.dart';

/// Import/export UI for portable `.dbscopeconn` connection links.
///
/// Export: pick a passphrase, encrypt the profile's password into the file.
/// Import: read the file, decrypt with the passphrase (or the
/// `DBSCOPE_CONN_PASSPHRASE` env var), then connect.
class ConnectionLinkFlow {
  ConnectionLinkFlow._();

  /// Env var checked before prompting on import — lets a saved link connect
  /// with zero interaction in a scripted/kiosk setup.
  static const String passphraseEnvVar = 'DBSCOPE_CONN_PASSPHRASE';

  static const XTypeGroup _typeGroup = XTypeGroup(
    label: 'dbscope connection',
    extensions: [ConnectionLink.fileExtension],
  );

  /// Encrypt [profile] into a `.dbscopeconn` file the user chooses.
  static Future<void> exportProfile(
    BuildContext context,
    ConnectionProfile profile,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (profile.password.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'This connection has no saved password to export. Connect once so '
            'the password is stored, then export.',
          ),
        ),
      );
      return;
    }

    final passphrase = await _promptPassphrase(context, confirm: true);
    if (passphrase == null) return;

    final String json;
    try {
      json = await ConnectionLink.encode(
        profile: profile,
        passphrase: passphrase,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
      return;
    }

    final location = await getSaveLocation(
      suggestedName:
          '${_safeName(profile.name)}.${ConnectionLink.fileExtension}',
      acceptedTypeGroups: const [_typeGroup],
    );
    if (location == null) return;

    try {
      await writeTextFile(location.path, json);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Saved connection link to ${location.path}')),
    );
  }

  /// Pick a `.dbscopeconn` file, decrypt it, and connect.
  static Future<void> importAndConnect(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await openFile(acceptedTypeGroups: const [_typeGroup]);
    if (file == null) return;

    final String jsonText;
    try {
      jsonText = await file.readAsString();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not read file: $e')),
      );
      return;
    }

    // Try the env-var passphrase first for a zero-prompt path.
    ConnectionProfile? profile;
    final envPass = envValue(passphraseEnvVar);
    if (envPass != null && envPass.isNotEmpty) {
      try {
        profile = await ConnectionLink.decode(
          jsonText: jsonText,
          passphrase: envPass,
        );
      } on BadPassphraseException {
        // Fall through to prompting.
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Not a valid connection file: $e')),
        );
        return;
      }
    }

    // Prompt, re-prompting on a wrong passphrase.
    var errorHint = false;
    while (profile == null) {
      if (!context.mounted) return;
      final passphrase = await _promptPassphrase(context, showError: errorHint);
      if (passphrase == null) return;
      try {
        profile = await ConnectionLink.decode(
          jsonText: jsonText,
          passphrase: passphrase,
        );
      } on BadPassphraseException {
        errorHint = true;
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Not a valid connection file: $e')),
        );
        return;
      }
    }

    if (!context.mounted) return;
    try {
      await ConnectionRegistry.instance.connectProfile(
        profile,
        context: context,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Connection failed: $e')));
    }
  }

  static Future<String?> _promptPassphrase(
    BuildContext context, {
    bool confirm = false,
    bool showError = false,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _PassphraseDialog(confirm: confirm, showError: showError),
    );
  }

  static String _safeName(String name) {
    final cleaned = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    final trimmed = cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'connection' : trimmed;
  }
}

class _PassphraseDialog extends StatefulWidget {
  final bool confirm;
  final bool showError;
  const _PassphraseDialog({required this.confirm, required this.showError});

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _visible = false;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_pass.text);
  }

  @override
  Widget build(BuildContext context) {
    return AppFormDialog(
      title: widget.confirm ? 'Set a passphrase' : 'Enter passphrase',
      submitLabel: widget.confirm ? 'Export' : 'Unlock',
      onSubmit: _submit,
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showError)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Wrong passphrase — try again.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Text(
              widget.confirm
                  ? 'The password is encrypted in the file with this '
                        'passphrase. Anyone loading the file will need it.'
                  : 'This connection file is encrypted. Enter its passphrase '
                        'to unlock and connect.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pass,
              autofocus: true,
              obscureText: !_visible,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _visible = !_visible),
                  icon: Icon(
                    _visible ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
              validator: (v) => (v == null || v.isEmpty) ? 'required' : null,
              onFieldSubmitted: (_) {
                if (!widget.confirm) _submit();
              },
            ),
            if (widget.confirm) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: !_visible,
                decoration: const InputDecoration(
                  labelText: 'Confirm passphrase',
                ),
                validator: (v) =>
                    v != _pass.text ? 'passphrases do not match' : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
