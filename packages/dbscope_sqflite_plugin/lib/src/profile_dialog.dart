// Three-step profile dialog: device → app → on-device .db file.
//
// Each step lazily probes the device via adb / xcrun devicectl (see
// app_data_explorer). The dialog is non-modal-friendly: every probe sets
// loading/error state so partial failures don't block the user from
// retrying.

import 'package:flutter/material.dart';
import 'package:dbscope/connection/profile.dart';

import 'device_picker.dart';
import 'plugin.dart';

Future<ConnectionProfile?> showSqfliteRemoteDialog(
  BuildContext context, {
  ConnectionProfile? initial,
}) {
  return showDialog<ConnectionProfile>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DeviceSqliteDialog(initial: initial),
  );
}

class _DeviceSqliteDialog extends StatefulWidget {
  final ConnectionProfile? initial;
  const _DeviceSqliteDialog({this.initial});

  @override
  State<_DeviceSqliteDialog> createState() => _DeviceSqliteDialogState();
}

class _DeviceSqliteDialogState extends State<_DeviceSqliteDialog> {
  final _name = TextEditingController();

  List<DiscoveredDevice> _devices = const [];
  String? _devicesHint;
  bool _devicesLoading = true;

  DiscoveredDevice? _device;
  List<DiscoveredApp> _apps = const [];
  bool _appsLoading = false;
  String? _appsError;

  String? _appId;
  List<DiscoveredDbFile> _dbs = const [];
  bool _dbsLoading = false;
  String? _dbsError;

  String? _dbPath;
  bool _readOnly = false;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i != null) {
      _name.text = i.name;
      _readOnly = i.readOnly;
      _appId = (i.extra['appId'] as String?)?.trim();
      _dbPath = (i.extra['dbPath'] as String?)?.trim();
    }
    _refreshDevices(restorePrior: i);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices({ConnectionProfile? restorePrior}) async {
    setState(() {
      _devicesLoading = true;
      _devicesHint = null;
    });
    final result = await discoverDevices();
    if (!mounted) return;
    setState(() {
      _devices = result.devices;
      _devicesHint = result.hint;
      _devicesLoading = false;
      _device = _matchPrior(result.devices, restorePrior);
    });
    if (_device != null) {
      await _loadApps(_device!);
    }
  }

  DiscoveredDevice? _matchPrior(
    List<DiscoveredDevice> devices,
    ConnectionProfile? prior,
  ) {
    if (prior == null) return devices.length == 1 ? devices.first : null;
    final kind = (prior.extra['deviceKind'] as String?) ?? '';
    final id = (prior.extra['deviceId'] as String?) ?? '';
    for (final d in devices) {
      if (d.kind == kind && d.id == id) return d;
    }
    return null;
  }

  Future<void> _loadApps(DiscoveredDevice device) async {
    setState(() {
      _appsLoading = true;
      _appsError = null;
      _apps = const [];
      // Keep _appId so the post-load matcher can re-select it; clear the
      // dependent steps.
      _dbs = const [];
      _dbPath = null;
      _dbsError = null;
    });
    try {
      final apps = await discoverApps(device);
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _appsLoading = false;
        // If the prior appId still exists on this device, keep it.
        if (_appId != null && apps.any((a) => a.id == _appId)) {
          // Trigger the next step.
        } else {
          _appId = null;
        }
      });
      if (_appId != null) {
        await _loadDbs(device, _appId!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _appsError = e.toString();
        _appsLoading = false;
      });
    }
  }

  Future<void> _loadDbs(DiscoveredDevice device, String appId) async {
    setState(() {
      _dbsLoading = true;
      _dbsError = null;
      _dbs = const [];
    });
    try {
      final backend = buildBackend(device, appId);
      final dbs = await discoverDbFiles(backend);
      if (!mounted) return;
      setState(() {
        _dbs = dbs;
        _dbsLoading = false;
        if (_dbPath != null && dbs.any((d) => d.relativePath == _dbPath)) {
          // Keep selection.
        } else {
          _dbPath = dbs.isNotEmpty ? dbs.first.relativePath : null;
        }
        if (_name.text.trim().isEmpty && _dbPath != null) {
          _name.text = _suggestName(appId, _dbPath!);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dbsError = e.toString();
        _dbsLoading = false;
      });
    }
  }

  String _suggestName(String appId, String dbPath) {
    final base = dbPath.split('/').last;
    final dot = base.lastIndexOf('.');
    final stem = dot <= 0 ? base : base.substring(0, dot);
    final appSuffix = appId.split('.').last;
    return '$stem ($appSuffix)';
  }

  bool get _canSubmit =>
      _name.text.trim().isNotEmpty &&
      _device != null &&
      _appId != null &&
      _dbPath != null;

  void _submit() {
    if (!_canSubmit) return;
    final device = _device!;
    final profile = ConnectionProfile(
      id: widget.initial?.id,
      kind: kSqfliteRemoteKind,
      name: _name.text.trim(),
      database: _dbPath!.split('/').last,
      readOnly: _readOnly,
      extra: {
        'deviceKind': device.kind,
        'deviceId': device.id,
        'deviceLabel': device.label,
        'appId': _appId,
        'dbPath': _dbPath,
      },
    );
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? 'New on-device SQLite connection'
            : 'Edit on-device SQLite connection',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _warningBanner(theme),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              _deviceRow(),
              const SizedBox(height: 12),
              _appRow(),
              const SizedBox(height: 12),
              _dbRow(),
              const SizedBox(height: 16),
              SwitchListTile(
                value: _readOnly,
                onChanged: (v) => setState(() => _readOnly = v),
                title: const Text('Read-only'),
                subtitle: const Text(
                  'Enforced locally via PRAGMA query_only. The on-device '
                  'file is only touched when you actually write.',
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
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _warningBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
        border:
            Border.all(color: theme.colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Force-stop the app on the device before editing. The DB file '
              'is pulled, edited locally, then pushed back; if the app '
              'writes between pull and push those changes are lost, and '
              'pushing while the app has the DB open can corrupt it.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _deviceRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: DropdownButtonFormField<DiscoveredDevice>(
            initialValue: _device,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Device',
              helperText: _devicesLoading
                  ? 'Scanning for connected devices...'
                  : _devicesHint ??
                      (_devices.isEmpty
                          ? 'No devices found. Plug in an Android (USB debugging) '
                              'or iOS (paired, developer mode) device and rescan.'
                          : null),
              helperMaxLines: 3,
            ),
            items: [
              for (final d in _devices)
                DropdownMenuItem(
                  value: d,
                  child: Text(
                    '${d.kind} ${d.label}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _devicesLoading
                ? null
                : (v) {
                    setState(() {
                      _device = v;
                      _apps = const [];
                      _appId = null;
                      _dbs = const [];
                      _dbPath = null;
                    });
                    if (v != null) _loadApps(v);
                  },
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Rescan devices',
          icon: _devicesLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          onPressed: _devicesLoading ? null : () => _refreshDevices(),
        ),
      ],
    );
  }

  Widget _appRow() {
    final disabled = _device == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _apps.any((a) => a.id == _appId) ? _appId : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'App',
              helperText: _appsError ??
                  (disabled
                      ? 'Pick a device first.'
                      : 'Lists only apps with reachable on-device data. '
                          'Android: debuggable APKs only.'),
              helperMaxLines: 3,
              errorText: _appsError,
            ),
            items: [
              for (final a in _apps)
                DropdownMenuItem(
                  value: a.id,
                  child: Text(
                    a.displayName == null ? a.id : '${a.displayName} (${a.id})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (_appsLoading || disabled)
                ? null
                : (v) {
                    setState(() {
                      _appId = v;
                      _dbs = const [];
                      _dbPath = null;
                    });
                    if (v != null && _device != null) _loadDbs(_device!, v);
                  },
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Rescan apps',
          icon: _appsLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          onPressed:
              (_appsLoading || disabled) ? null : () => _loadApps(_device!),
        ),
      ],
    );
  }

  Widget _dbRow() {
    final disabled = _appId == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue:
                _dbs.any((d) => d.relativePath == _dbPath) ? _dbPath : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Database file',
              helperText: _dbsError ??
                  (disabled
                      ? 'Pick an app first.'
                      : _dbs.isEmpty && !_dbsLoading
                          ? 'No .db / .sqlite / .sqlite3 files found in the app data container.'
                          : 'Scanned recursively from the app data container root.'),
              helperMaxLines: 3,
              errorText: _dbsError,
            ),
            items: [
              for (final db in _dbs)
                DropdownMenuItem(
                  value: db.relativePath,
                  child: Text(
                    db.sizeBytes == null
                        ? db.relativePath
                        : '${db.relativePath} (${_fmtSize(db.sizeBytes!)})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (_dbsLoading || disabled)
                ? null
                : (v) => setState(() {
                      _dbPath = v;
                      if (v != null &&
                          _name.text.trim().isEmpty &&
                          _appId != null) {
                        _name.text = _suggestName(_appId!, v);
                      }
                    }),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Rescan files',
          icon: _dbsLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          onPressed: (_dbsLoading || disabled)
              ? null
              : () => _loadDbs(_device!, _appId!),
        ),
      ],
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
