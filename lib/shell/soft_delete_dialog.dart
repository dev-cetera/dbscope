import 'package:flutter/material.dart';

/// Result of the soft-delete configuration dialog. [clear] means the
/// user wants the override removed entirely; otherwise [column] holds
/// the new column name (non-empty).
class SoftDeleteResult {
  const SoftDeleteResult.set(this.column) : clear = false;
  const SoftDeleteResult.cleared() : column = null, clear = true;
  final String? column;
  final bool clear;
}

/// Modal dialog letting the user pick or clear the soft-delete column
/// for a table. Returns null if cancelled.
Future<SoftDeleteResult?> showSoftDeleteDialog(
  BuildContext context, {
  required String schema,
  required String table,
  String? initialColumn,
}) {
  return showDialog<SoftDeleteResult>(
    context: context,
    builder: (_) => _SoftDeleteDialog(
      schema: schema,
      table: table,
      initialColumn: initialColumn,
    ),
  );
}

class _SoftDeleteDialog extends StatefulWidget {
  const _SoftDeleteDialog({
    required this.schema,
    required this.table,
    required this.initialColumn,
  });
  final String schema;
  final String table;
  final String? initialColumn;

  @override
  State<_SoftDeleteDialog> createState() => _SoftDeleteDialogState();
}

class _SoftDeleteDialogState extends State<_SoftDeleteDialog> {
  late final TextEditingController _columnController;

  @override
  void initState() {
    super.initState();
    _columnController = TextEditingController(text: widget.initialColumn ?? '');
  }

  @override
  void dispose() {
    _columnController.dispose();
    super.dispose();
  }

  void _save() {
    final text = _columnController.text.trim();
    if (text.isEmpty) {
      Navigator.of(context).pop(const SoftDeleteResult.cleared());
    } else {
      Navigator.of(context).pop(SoftDeleteResult.set(text));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Soft-delete for ${widget.schema}.${widget.table}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'When set, the Delete button issues '
              'UPDATE … SET <column> = now() instead of DELETE, '
              'and the grid hides rows where the column IS NULL is false.\n\n'
              'Leave blank and Save to clear the setting.',
            ),
            const SizedBox(height: 12.0),
            TextField(
              controller: _columnController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Column name',
                hintText: 'e.g. deleted_at',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (widget.initialColumn != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(const SoftDeleteResult.cleared()),
            child: const Text('Clear'),
          ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
