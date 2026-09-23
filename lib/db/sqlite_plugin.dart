import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import '../connection/profile.dart';
import '../plugins/dbscope_plugin.dart';
import 'plugin.dart';
import 'sqlite_executor.dart';

/// Universal-plugin wrapper for the built-in SQLite kind.
class SqlitePlugin extends DbscopePlugin {
  @override
  String get id => kSqliteKind;
  @override
  String get label => 'SQLite';

  @override
  void register(DbscopeHost host) {
    host.connections.register(const SqliteKindPlugin());
  }
}

/// Built-in SQLite kind. Owns a path-based connection to a local
/// `.db`/`.sqlite` file. The file path lives in `profile.extra['path']`
/// (the core never reads it; this plugin is the only interpreter).
class SqliteKindPlugin implements ConnectionKindPlugin {
  const SqliteKindPlugin();

  @override
  String get id => kSqliteKind;

  @override
  String get label => 'SQLite';

  @override
  Future<OpenResult> open(
    ConnectionProfile profile, {
    BuildContext? context,
  }) async {
    final path = (profile.extra['path'] as String?)?.trim();
    if (path == null || path.isEmpty) {
      throw StateError('SQLite profile has no file path set.');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('SQLite file does not exist: $path');
    }
    // Always open read-write so toggling read-only via PRAGMA query_only
    // is possible. The registry calls setReadOnly after open based on the
    // profile's readOnly flag.
    final db = sq.sqlite3.open(path);
    db.execute('PRAGMA foreign_keys = ON');
    return OpenResult(executor: SqliteExecutor(db));
  }

  @override
  Future<ConnectionProfile?> showProfileDialog(
    BuildContext context, {
    ConnectionProfile? initial,
  }) {
    return showDialog<ConnectionProfile>(
      context: context,
      builder: (_) => SqliteConnectionDialog(initial: initial),
    );
  }
}

class SqliteConnectionDialog extends StatefulWidget {
  final ConnectionProfile? initial;
  const SqliteConnectionDialog({super.key, this.initial});

  @override
  State<SqliteConnectionDialog> createState() => _SqliteConnectionDialogState();
}

class _SqliteConnectionDialogState extends State<SqliteConnectionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _path;
  bool _readOnly = false;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? '');
    _path = TextEditingController(
      text: (i?.extra['path'] as String?) ?? '',
    );
    _readOnly = i?.readOnly ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'SQLite',
          extensions: ['db', 'sqlite', 'sqlite3', 'db3'],
        ),
        XTypeGroup(label: 'All files'),
      ],
    );
    if (picked == null) return;
    setState(() {
      _path.text = picked.path;
      if (_name.text.trim().isEmpty) {
        _name.text = _basenameNoExt(picked.path);
      }
    });
  }

  String _basenameNoExt(String p) {
    final sep = p.contains(r'\') ? r'\' : '/';
    final base = p.split(sep).last;
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final path = _path.text.trim();
    final base = _basenameNoExt(path);
    final profile = ConnectionProfile(
      id: widget.initial?.id,
      kind: kSqliteKind,
      name: _name.text.trim(),
      // Reuse `database` for picker display.
      database: base,
      readOnly: _readOnly,
      extra: {'path': path},
    );
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? 'New SQLite connection'
            : 'Edit SQLite connection',
      ),
      content: SizedBox(
        width: 480,
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _path,
                      decoration: const InputDecoration(
                        labelText: 'Database file',
                        hintText: '/path/to/your.db',
                      ),
                      validator: _req,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Browse',
                    icon: const Icon(Icons.folder_open),
                    onPressed: _pickFile,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _readOnly,
                onChanged: (v) => setState(() => _readOnly = v),
                title: const Text('Read-only'),
                subtitle: const Text(
                  'Enforced via PRAGMA query_only',
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ],
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

  String? _req(String? v) =>
      (v == null || v.trim().isEmpty) ? 'required' : null;
}
