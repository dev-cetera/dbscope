import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import 'profile.dart';

class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({super.key, this.initial});
  final ConnectionProfile? initial;

  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  /// Highest valid TCP port number.
  static const _kMaxPort = 65535;

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
  var _readOnly = true;

  /// Whether the read-only switch shows the user's own choice. Until they
  /// touch it on a new profile, it follows [suggestReadOnly] as they type
  /// the name and host, and says why.
  var _readOnlyChosen = false;

  /// Same as [_readOnlyChosen], for the SSL mode: until the user picks one
  /// on a new profile, it follows [suggestSslMode] as they type the host.
  var _sslChosen = false;
  var _passwordVisible = false;
  var _forgetPassword = false;

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
    _sslMode = i?.sslMode ?? suggestSslMode(_host.text);
    _sslChosen = i != null;
    _readOnlyChosen = i != null;
    _readOnly = i?.readOnly ?? _suggestion.readOnly;
    _name.addListener(_followSuggestion);
    _host.addListener(_followSuggestion);
  }

  ({bool readOnly, String reason}) get _suggestion =>
      suggestReadOnly(name: _name.text, host: _host.text);

  void _followSuggestion() {
    final readOnly = _readOnlyChosen ? _readOnly : _suggestion.readOnly;
    final ssl = _sslChosen ? _sslMode : suggestSslMode(_host.text);
    if (readOnly == _readOnly && ssl == _sslMode) return;
    setState(() {
      _readOnly = readOnly;
      _sslMode = ssl;
    });
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
    final column = _tenantColumn.text.trim();
    final raw = _tenantValue.text.trim();
    if (column.isEmpty || raw.isEmpty) return null;
    // Try int first so `account_id = 42` works against an integer column.
    // Fall back to string — PG will implicitly cast text to uuid /
    // timestamptz / etc. on equality.
    final asInt = int.tryParse(raw);
    return TenantFilter(column: column, value: asInt ?? raw);
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
      password: _forgetPassword ? '' : _password.text,
      forgetPassword: _forgetPassword,
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
            FieldName(
              'Name',
              child: TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: _validateRequired,
              ),
            ),
            const SizedBox(height: 12.0),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FieldName(
                    'Host',
                    child: TextFormField(
                      controller: _host,
                      decoration: const InputDecoration(labelText: 'Host'),
                      validator: _validateRequired,
                    ),
                  ),
                ),
                const SizedBox(width: 12.0),
                Expanded(
                  child: FieldName(
                    'Port',
                    child: TextFormField(
                      controller: _port,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                      validator: (text) {
                        if (text == null || text.isEmpty) return 'required';
                        final port = int.tryParse(text);
                        if (port == null || port <= 0 || port > _kMaxPort) {
                          return 'invalid';
                        }
                        return null;
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12.0),
            FieldName(
              'Database',
              child: TextFormField(
                controller: _database,
                decoration: const InputDecoration(labelText: 'Database'),
                validator: _validateRequired,
              ),
            ),
            const SizedBox(height: 12.0),
            FieldName(
              'Username',
              child: TextFormField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: _validateRequired,
              ),
            ),
            const SizedBox(height: 12.0),
            FieldName(
              'Password',
              child: TextFormField(
                controller: _password,
                enabled: !_forgetPassword,
                obscureText: !_passwordVisible,
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: widget.initial == null || _forgetPassword
                      ? null
                      : 'Leave empty to keep the saved password.',
                  suffixIcon: IconButton(
                    onPressed: () => setState(
                      () => _passwordVisible = !_passwordVisible,
                    ),
                    icon: Icon(
                      _passwordVisible ? Icons.visibility_off : Icons.visibility,
                      semanticLabel:
                          _passwordVisible ? 'Hide password' : 'Show password',
                    ),
                  ),
                ),
              ),
            ),
            if (widget.initial != null)
              CheckboxListTile(
                value: _forgetPassword,
                onChanged: (value) => setState(() {
                  _forgetPassword = value ?? false;
                  if (_forgetPassword) _password.clear();
                }),
                title: const Text('Forget the saved password'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            const SizedBox(height: 12.0),
            InstantDropdown(
              decoration: const InputDecoration(labelText: 'SSL mode'),
              isExpanded: true,
              items: [
                for (final (mode, label) in const [
                  (SslMode.disable, 'disable'),
                  (SslMode.require, 'require'),
                  (SslMode.verifyFull, 'verify-full'),
                ])
                  InstantDropdownItem(
                    label: label,
                    selected: mode == _sslMode,
                    onSelected: () => setState(() {
                      _sslMode = mode;
                      _sslChosen = true;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12.0),
            SwitchListTile(
              value: _readOnly,
              onChanged: (readOnly) => setState(() {
                _readOnly = readOnly;
                _readOnlyChosen = true;
              }),
              title: const Text('Read-only'),
              subtitle: Text(
                _readOnlyChosen
                    ? 'Blocks every write on this connection.'
                    : '${_readOnly ? 'On' : 'Off'} because ${_suggestion.reason}. '
                          'Blocks every write on this connection.',
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const Divider(height: 24.0),
            Text(
              'Default tenant filter (optional)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4.0),
            Text(
              'When set, every table that has this column gets '
              '"<column> = <value>" added to its WHERE. Tables without '
              'the column are unaffected. Leave blank to disable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8.0),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: FieldName(
                    'Column',
                    child: TextFormField(
                      controller: _tenantColumn,
                      decoration: const InputDecoration(
                        labelText: 'Column',
                        hintText: 'e.g. account_id',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12.0),
                Expanded(
                  flex: 3,
                  child: FieldName(
                    'Value',
                    child: TextFormField(
                      controller: _tenantValue,
                      decoration: const InputDecoration(
                        labelText: 'Value',
                        hintText: 'pasted as text; ints auto-detected',
                      ),
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

  String? _validateRequired(String? text) =>
      (text == null || text.trim().isEmpty) ? 'required' : null;
}
