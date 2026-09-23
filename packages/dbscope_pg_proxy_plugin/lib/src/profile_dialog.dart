import 'package:dbscope/connection/profile.dart';
import 'package:flutter/material.dart';

import 'plugin.dart' show kPgProxyKind;

Future<ConnectionProfile?> showPgProxyDialog(
  BuildContext context, {
  ConnectionProfile? initial,
}) {
  return showDialog<ConnectionProfile>(
    context: context,
    builder: (_) => _PgProxyDialog(initial: initial),
  );
}

class _PgProxyDialog extends StatefulWidget {
  final ConnectionProfile? initial;
  const _PgProxyDialog({this.initial});

  @override
  State<_PgProxyDialog> createState() => _PgProxyDialogState();
}

class _PgProxyDialogState extends State<_PgProxyDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _proxyUrl;
  late final TextEditingController _sharedSecret;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  SslMode _ssl = SslMode.require;
  bool _readOnly = false;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? '');
    _proxyUrl = TextEditingController(
      text: (i?.extra['proxyUrl'] as String?) ?? 'ws://127.0.0.1:8765',
    );
    _sharedSecret = TextEditingController(
      text: (i?.extra['sharedSecret'] as String?) ?? '',
    );
    _host = TextEditingController(text: i?.host ?? 'localhost');
    _port = TextEditingController(text: '${i?.port ?? 5432}');
    _database = TextEditingController(text: i?.database ?? '');
    _username = TextEditingController(text: i?.username ?? '');
    _password = TextEditingController(text: i?.password ?? '');
    _ssl = i?.sslMode ?? SslMode.require;
    _readOnly = i?.readOnly ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _proxyUrl.dispose();
    _sharedSecret.dispose();
    _host.dispose();
    _port.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final profile = ConnectionProfile(
      id: widget.initial?.id,
      kind: kPgProxyKind,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 5432,
      database: _database.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      sslMode: _ssl,
      readOnly: _readOnly,
      extra: {
        'proxyUrl': _proxyUrl.text.trim(),
        if (_sharedSecret.text.isNotEmpty) 'sharedSecret': _sharedSecret.text,
      },
    );
    Navigator.of(context).pop(profile);
  }

  String? _req(String? v) =>
      (v == null || v.trim().isEmpty) ? 'required' : null;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? 'New PostgreSQL connection (via proxy)'
            : 'Edit PostgreSQL connection (via proxy)',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: _req,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Proxy',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                TextFormField(
                  controller: _proxyUrl,
                  decoration: const InputDecoration(
                    labelText: 'Proxy WebSocket URL',
                    hintText: 'ws://127.0.0.1:8765 or wss://your.host',
                  ),
                  validator: _req,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _sharedSecret,
                  decoration: const InputDecoration(
                    labelText: 'Shared secret (optional)',
                    hintText: 'Matches the proxy\'s --shared-secret',
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Postgres',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _host,
                        decoration: const InputDecoration(labelText: 'Host'),
                        validator: _req,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _port,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _database,
                  decoration: const InputDecoration(labelText: 'Database'),
                  validator: _req,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _username,
                  decoration: const InputDecoration(labelText: 'Username'),
                  validator: _req,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _password,
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<SslMode>(
                  initialValue: _ssl,
                  decoration: const InputDecoration(labelText: 'SSL mode'),
                  items: const [
                    DropdownMenuItem(
                      value: SslMode.disable,
                      child: Text('disable'),
                    ),
                    DropdownMenuItem(
                      value: SslMode.require,
                      child: Text('require'),
                    ),
                    DropdownMenuItem(
                      value: SslMode.verifyFull,
                      child: Text('verify-full'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _ssl = v ?? SslMode.require),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: _readOnly,
                  onChanged: (v) => setState(() => _readOnly = v),
                  title: const Text('Read-only'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Connect')),
      ],
    );
  }
}
