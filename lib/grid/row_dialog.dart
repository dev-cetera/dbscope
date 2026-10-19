import 'package:flutter/material.dart';

import '../db/edit_policy.dart';
import 'inputs/column_input.dart';

class InsertRowDialog extends StatefulWidget {
  const InsertRowDialog({super.key, required this.policies});
  final List<EditPolicy> policies;

  @override
  State<InsertRowDialog> createState() => _InsertRowDialogState();
}

class _InsertRowDialogState extends State<InsertRowDialog> {
  late final Map<String, Object?> _values;
  late final Set<String> _touched;

  @override
  void initState() {
    super.initState();
    _values = {
      for (final policy in widget.policies.where((policy) => !policy.readOnly)) policy.column: null,
    };
    _touched = <String>{};
  }

  void _submit() {
    final out = <String, Object?>{};
    for (final policy in widget.policies.where((policy) => !policy.readOnly)) {
      final value = _values[policy.column];
      // Skip columns the user never touched and that ended up empty,
      // so column defaults / sequences kick in.
      if (!_touched.contains(policy.column)) {
        if (value == null) continue;
        if (value is String && value.isEmpty) continue;
      }
      out[policy.column] = value;
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editable = widget.policies.where((policy) => !policy.readOnly).toList();
    return AlertDialog(
      title: const Text('Insert row'),
      content: SizedBox(
        width: 520.0,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final policy in editable)
                ColumnInput.forPolicy(
                  policy: policy,
                  value: _values[policy.column],
                  onChanged: (value) {
                    setState(() {
                      _values[policy.column] = value;
                      _touched.add(policy.column);
                    });
                  },
                ),
              if (editable.isEmpty)
                Text(
                  'No editable columns. The table may have no PK or all columns are generated/identity.',
                  style: theme.textTheme.bodySmall,
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
          onPressed: editable.isEmpty ? null : _submit,
          child: const Text('Insert'),
        ),
      ],
    );
  }
}
