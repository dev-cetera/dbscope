import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import 'profile.dart';

class ConnectionDialog extends StatefulWidget {
  final ConnectionProfile? initial;
  const ConnectionDialog({super.key, this.initial});

  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _tenantColumn;
  late final TextEditingController _tenantValue;
  SslMode _sslMode = SslMode.disable;
  bool _readOnly = true;
  bool _passwordVisible = false;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? 'local');
    _host = TextEditingController(text: i?.host ?? 'localhost');
    _port = TextEditingController(text: (i?.port ?? 5432).toString());
    _database = TextEditingController(text: i?.database ?? 'postgres');
    _username = TextEditingController(text: i?.username ?? 'postgres');
    _password = TextEditingController(text: i?.password ?? '');
    _tenantColumn = TextEditingController(text: i?.tenantFilter?.column ?? '');
    _tenantValue = TextEditingController(
      text: i?.tenantFilter?.value?.toString() ?? '',
    );
    _sslMode = i?.sslMode ?? SslMode.disable;
    _readOnly = i?.readOnly ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    _tenantColumn.dispose();
    _tenantValue.dispose();
    super.dispose();
  }

  TenantFilter? _buildTenantFilter() {
    final col = _tenantColumn.text.trim();
    final raw = _tenantValue.text.trim();
    if (col.isEmpty || raw.isEmpty) return null;
    // Try int first so `account_id = 42` works against an integer column.
    // Fall back to string — PG will implicitly cast text to uuid /
    // timestamptz / etc. on equality.
    final asInt = int.tryParse(raw);
    return TenantFilter(column: col, value: asInt ?? raw);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final profile = ConnectionProfile(
      id: widget.initial?.id,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      database: _database.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      sslMode: _sslMode,
      readOnly: _readOnly,
      tenantFilter: _buildTenantFilter(),
      tableOverrides: widget.initial?.tableOverrides,
    );
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    return AppFormDialog(
      title: widget.initial == null ? 'New connection' : 'Edit connection',
      submitLabel: 'Connect',
      onSubmit: _submit,
      content: Form(
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
            const SizedBox(height: 12),
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
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: 'Port'),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'required';
                      final p = int.tryParse(v);
                      if (p == null || p <= 0 || p > 65535) return 'invalid';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _database,
              decoration: const InputDecoration(labelText: 'Database'),
              validator: _req,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Username'),
              validator: _req,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: !_passwordVisible,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  onPressed: () => setState(
                    () => _passwordVisible = !_passwordVisible,
                  ),
                  icon: Icon(
                    _passwordVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SslMode>(
              initialValue: _sslMode,
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
              onChanged: (v) => setState(() => _sslMode = v ?? SslMode.disable),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _readOnly,
              onChanged: (v) => setState(() => _readOnly = v),
              title: const Text('Read-only'),
              subtitle: const Text(
                'Enforced via SET default_transaction_read_only',
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const Divider(height: 24),
            Text(
              'Default tenant filter (optional)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'When set, every table that has this column gets '
              '"<column> = <value>" added to its WHERE. Tables without '
              'the column are unaffected. Leave blank to disable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _tenantColumn,
                    decoration: const InputDecoration(
                      labelText: 'Column',
                      hintText: 'e.g. account_id',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _tenantValue,
                    decoration: const InputDecoration(
                      labelText: 'Value',
                      hintText: 'pasted as text; ints auto-detected',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String? _req(String? v) =>
      (v == null || v.trim().isEmpty) ? 'required' : null;
}
