import 'package:flutter/material.dart';

import '../db/edit_policy.dart';
import 'inputs/column_input.dart';

class InsertRowDialog extends StatefulWidget {
  final List<EditPolicy> policies;
  const InsertRowDialog({super.key, required this.policies});

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
      for (final p in widget.policies.where((p) => !p.readOnly)) p.column: null,
    };
    _touched = <String>{};
  }

  void _submit() {
    final out = <String, Object?>{};
    for (final p in widget.policies.where((p) => !p.readOnly)) {
      final v = _values[p.column];
      // Skip columns the user never touched and that ended up empty,
      // so column defaults / sequences kick in.
      if (!_touched.contains(p.column)) {
        if (v == null) continue;
        if (v is String && v.isEmpty) continue;
      }
      out[p.column] = v;
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editable = widget.policies.where((p) => !p.readOnly).toList();
    return AlertDialog(
      title: const Text('Insert row'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in editable)
                ColumnInput.forPolicy(
                  policy: p,
                  value: _values[p.column],
                  onChanged: (v) {
                    setState(() {
                      _values[p.column] = v;
                      _touched.add(p.column);
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
