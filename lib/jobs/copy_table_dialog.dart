// Dialog for launching a Copy Table job. Lets the user pick a target
// connection from the shared profile list, override target schema/table
// names, and choose append vs truncate.

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../../connection/profile.dart';
import '../../connection/registry.dart';

class CopyTableTarget {
  const CopyTableTarget({
    required this.target,
    required this.targetSchema,
    required this.targetTable,
    required this.mode,
  });
  final ConnectionProfile target;
  final String targetSchema;
  final String targetTable;
  final String mode;
}

class CopyTableDialog extends StatefulWidget {
  const CopyTableDialog({
    super.key,
    required this.sourceConnectionId,
    required this.sourceSchema,
    required this.sourceTable,
    required this.profiles,
  });
  final String sourceConnectionId;
  final String sourceSchema;
  final String sourceTable;
  final List<ConnectionProfile> profiles;

  @override
  State<CopyTableDialog> createState() => _CopyTableDialogState();
}

class _CopyTableDialogState extends State<CopyTableDialog> {
  late TextEditingController _schemaController;
  late TextEditingController _tableController;
  String? _targetId;
  var _mode = 'append';

  @override
  void initState() {
    super.initState();
    _schemaController = TextEditingController(text: widget.sourceSchema);
    _tableController = TextEditingController(text: widget.sourceTable);
    // Default to a different profile if any exists.
    final others = widget.profiles
        .where((profile) => profile.id != widget.sourceConnectionId)
        .toList();
    if (others.isNotEmpty) _targetId = others.first.id;
  }

  @override
  void dispose() {
    _schemaController.dispose();
    _tableController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = ConnectionRegistry.instance.profileById(
      widget.sourceConnectionId,
    );
    final targetReadOnly =
        _targetId != null &&
        widget.profiles.firstWhere((profile) => profile.id == _targetId).readOnly;
    return AppFormDialog(
      title: 'Copy table to…',
      submitLabel: 'Run',
      submitIcon: Icons.play_arrow,
      onSubmit: _targetId == null
          ? null
          : () {
              final target = widget.profiles.firstWhere(
                (profile) => profile.id == _targetId,
              );
              Navigator.of(context).pop(
                CopyTableTarget(
                  target: target,
                  targetSchema: _schemaController.text.trim(),
                  targetTable: _tableController.text.trim(),
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
          const SizedBox(height: 12.0),
          DropdownButtonFormField<String>(
            initialValue: _targetId,
            decoration: const InputDecoration(
              labelText: 'Target connection',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final profile in widget.profiles)
                DropdownMenuItem(
                  value: profile.id,
                  enabled: profile.id != widget.sourceConnectionId,
                  child: Row(
                    children: [
                      Expanded(child: Text(profile.name)),
                      if (profile.readOnly)
                        const Padding(
                          padding: EdgeInsets.only(left: 4.0),
                          child: Text(
                            'RO',
                            style: TextStyle(fontSize: 10.0),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            onChanged: (targetId) => setState(() => _targetId = targetId),
          ),
          const SizedBox(height: 12.0),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _schemaController,
                  decoration: const InputDecoration(
                    labelText: 'Target schema',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8.0),
              Expanded(
                child: TextField(
                  controller: _tableController,
                  decoration: const InputDecoration(
                    labelText: 'Target table',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12.0),
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
            onChanged: (mode) {
              if (mode != null) setState(() => _mode = mode);
            },
          ),
          if (targetReadOnly)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
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
