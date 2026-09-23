import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../../connection/profile.dart';
import 'cloudsql_config.dart';

/// New/edit dialog for a Cloud SQL (Postgres via Auth Proxy) connection.
class CloudSqlDialog extends StatefulWidget {
  final ConnectionProfile? initial;
  const CloudSqlDialog({super.key, this.initial});

  @override
  State<CloudSqlDialog> createState() => _CloudSqlDialogState();
}

class _CloudSqlDialogState extends State<CloudSqlDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _instance;
  late final TextEditingController _project;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _localPort;
  late final TextEditingController _proxyPath;
  late final TextEditingController _gcloudPath;
  bool _assignPublicIp = true;
  bool _readOnly = true;
  bool _passwordVisible = false;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    final cfg = i == null ? null : CloudSqlConfig.fromProfile(i);
    _name = TextEditingController(text: i?.name ?? 'cloud sql');
    _instance = TextEditingController(
      text: cfg?.instanceConnectionName ?? '',
    );
    _project = TextEditingController(text: cfg?.gcpProject ?? '');
    _database = TextEditingController(text: i?.database ?? 'postgres');
    _username = TextEditingController(text: i?.username ?? 'postgres');
    _password = TextEditingController(text: i?.password ?? '');
    _localPort = TextEditingController(
      text: (cfg?.localPort ?? 9480).toString(),
    );
    _proxyPath = TextEditingController(text: cfg?.cloudSqlProxyPath ?? '');
    _gcloudPath = TextEditingController(text: cfg?.gcloudPath ?? '');
    _assignPublicIp = cfg?.assignPublicIp ?? true;
    _readOnly = i?.readOnly ?? true;
    // Auto-fill the project from the instance name until the user edits it.
    _instance.addListener(_maybeSyncProject);
  }

  void _maybeSyncProject() {
    final segs = _instance.text.trim().split(':');
    if (segs.isNotEmpty &&
        segs.first.isNotEmpty &&
        _project.text.trim().isEmpty) {
      _project.text = segs.first;
    }
  }

  @override
  void dispose() {
    _instance.removeListener(_maybeSyncProject);
    _name.dispose();
    _instance.dispose();
    _project.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    _localPort.dispose();
    _proxyPath.dispose();
    _gcloudPath.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final instance = _instance.text.trim();
    final segs = instance.split(':');
    final project = _project.text.trim().isNotEmpty
        ? _project.text.trim()
        : (segs.isNotEmpty ? segs.first : '');
    final instanceName = segs.isNotEmpty ? segs.last : '';
    final port = int.parse(_localPort.text.trim());
    final cfg = CloudSqlConfig(
      instanceConnectionName: instance,
      gcpProject: project,
      instanceName: instanceName,
      localPort: port,
      assignPublicIp: _assignPublicIp,
      cloudSqlProxyPath: _proxyPath.text.trim(),
      gcloudPath: _gcloudPath.text.trim(),
    );
    final profile = ConnectionProfile(
      id: widget.initial?.id,
      kind: kCloudSqlKind,
      name: _name.text.trim(),
      host: '127.0.0.1',
      port: port,
      database: _database.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      sslMode: SslMode.disable,
      readOnly: _readOnly,
      extra: cfg.toExtra(),
      tenantFilter: widget.initial?.tenantFilter,
      tableOverrides: widget.initial?.tableOverrides,
    );
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    return AppFormDialog(
      title: widget.initial == null
          ? 'New Cloud SQL connection'
          : 'Edit Cloud SQL connection',
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
            TextFormField(
              controller: _instance,
              decoration: const InputDecoration(
                labelText: 'Instance connection name',
                hintText: 'project:region:instance',
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'required';
                if (v.trim().split(':').length != 3) {
                  return 'expected project:region:instance';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _project,
              decoration: const InputDecoration(
                labelText: 'GCP project (for public-IP toggle)',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _database,
                    decoration: const InputDecoration(labelText: 'Database'),
                    validator: _req,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _localPort,
                    decoration: const InputDecoration(labelText: 'Local port'),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final p = int.tryParse(v?.trim() ?? '');
                      if (p == null || p <= 0 || p > 65535) return 'invalid';
                      return null;
                    },
                  ),
                ),
              ],
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
                  onPressed: () =>
                      setState(() => _passwordVisible = !_passwordVisible),
                  icon: Icon(
                    _passwordVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _assignPublicIp,
              onChanged: (v) => setState(() => _assignPublicIp = v),
              title: const Text('Assign public IP on connect'),
              subtitle: const Text(
                'Needed for private-only instances reached from a laptop. '
                'Removed again on disconnect.',
              ),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              value: _readOnly,
              onChanged: (v) => setState(() => _readOnly = v),
              title: const Text('Read-only'),
              subtitle: const Text(
                'Enforced via SET default_transaction_read_only',
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: () => setState(() => _showAdvanced = !_showAdvanced),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _showAdvanced ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    const SizedBox(width: 4),
                    const Text('Advanced (binary paths)'),
                  ],
                ),
              ),
            ),
            if (_showAdvanced) ...[
              TextFormField(
                controller: _proxyPath,
                decoration: const InputDecoration(
                  labelText: 'cloud-sql-proxy path (optional)',
                  hintText: 'auto-detected from PATH if blank',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _gcloudPath,
                decoration: const InputDecoration(
                  labelText: 'gcloud path (optional)',
                  hintText: 'auto-detected from PATH if blank',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _req(String? v) =>
      (v == null || v.trim().isEmpty) ? 'required' : null;
}
