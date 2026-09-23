// Dialog for launching a Copy Table job. Lets the user pick a target
// connection from the shared profile list, override target schema/table
// names, and choose append vs truncate.

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../../connection/profile.dart';
import '../../connection/registry.dart';

class CopyTableTarget {
  final ConnectionProfile target;
  final String targetSchema;
  final String targetTable;
  final String mode;
  const CopyTableTarget({
    required this.target,
    required this.targetSchema,
    required this.targetTable,
    required this.mode,
  });
}

class CopyTableDialog extends StatefulWidget {
  final String sourceConnectionId;
  final String sourceSchema;
  final String sourceTable;
  final List<ConnectionProfile> profiles;

  const CopyTableDialog({
    super.key,
    required this.sourceConnectionId,
    required this.sourceSchema,
    required this.sourceTable,
    required this.profiles,
  });

  @override
  State<CopyTableDialog> createState() => _CopyTableDialogState();
}

class _CopyTableDialogState extends State<CopyTableDialog> {
  late TextEditingController _schemaCtrl;
  late TextEditingController _tableCtrl;
  String? _targetId;
  String _mode = 'append';

  @override
  void initState() {
    super.initState();
    _schemaCtrl = TextEditingController(text: widget.sourceSchema);
    _tableCtrl = TextEditingController(text: widget.sourceTable);
    // Default to a different profile if any exists.
    final others = widget.profiles
        .where((p) => p.id != widget.sourceConnectionId)
        .toList();
    if (others.isNotEmpty) _targetId = others.first.id;
  }

  @override
  void dispose() {
    _schemaCtrl.dispose();
    _tableCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = ConnectionRegistry.instance.profileById(
      widget.sourceConnectionId,
    );
    final targetReadOnly = _targetId != null
        ? widget.profiles.firstWhere((p) => p.id == _targetId).readOnly
        : false;
    return AppFormDialog(
      title: 'Copy table to…',
      submitLabel: 'Run',
      submitIcon: Icons.play_arrow,
      onSubmit: _targetId == null
          ? null
          : () {
              final target = widget.profiles.firstWhere(
                (p) => p.id == _targetId,
              );
              Navigator.of(context).pop(
                CopyTableTarget(
                  target: target,
                  targetSchema: _schemaCtrl.text.trim(),
                  targetTable: _tableCtrl.text.trim(),
                  mode: _mode,
                ),
              );
            },
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Source: ${source?.name ?? widget.sourceConnectionId}'
            ' • ${widget.sourceSchema}.${widget.sourceTable}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.hintColor,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _targetId,
            decoration: const InputDecoration(
              labelText: 'Target connection',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final p in widget.profiles)
                DropdownMenuItem(
                  value: p.id,
                  enabled: p.id != widget.sourceConnectionId,
                  child: Row(
                    children: [
                      Expanded(child: Text(p.name)),
                      if (p.readOnly)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Text(
                            'RO',
                            style: TextStyle(fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _targetId = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _schemaCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Target schema',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _tableCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Target table',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: 'Mode',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'append', child: Text('Append (INSERT)')),
              DropdownMenuItem(
                value: 'truncate',
                child: Text('Replace (TRUNCATE then INSERT)'),
              ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _mode = v);
            },
          ),
          if (targetReadOnly)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Target is marked read-only — job will fail unless you '
                'toggle read-write first.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
