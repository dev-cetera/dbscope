import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../code/code_editor_launcher.dart';
import 'inputs/column_input.dart' show compactJson;

/// Render any cell value as JSON source text. `package:postgres` decodes
/// `json`/`jsonb` columns to live Dart values (Map / List / String /
/// num / bool / null), so `.toString()` on a Map yields `{a: 1}` (Dart
/// syntax, not JSON) and on a `"hello"`-jsonb value yields `hello`
/// without the surrounding quotes. Both make `jsonDecode` fail and the
/// editor dialog flag the value as "Invalid JSON". This helper round-
/// trips through `jsonEncode` so the dialog always opens with valid
/// JSON source — strings that already parse (e.g. JSON stored in a
/// `text` column) are passed through untouched.
String jsonSourceOf(Object? v) {
  if (v == null) return '';
  if (v is String) {
    try {
      jsonDecode(v);
      return v;
    } catch (_) {
      return jsonEncode(v);
    }
  }
  return jsonEncode(v);
}

/// Read-only JSON viewer dialog. Pretty-printed, syntax-highlighted via
/// the shared [CodeViewer]. The "Open in new tab" action is opt-in via
/// [onOpenInNewTab]; callers that don't supply it get a viewer without
/// that button. The dialog itself stays decoupled from tab/connection
/// state.
class JsonViewerDialog extends StatelessWidget {
  final String columnName;
  final String pretty;
  final VoidCallback? onOpenInNewTab;
  const JsonViewerDialog({
    super.key,
    required this.columnName,
    required this.pretty,
    this.onOpenInNewTab,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(columnName),
      content: SizedBox(
        width: 560,
        height: 420,
        child: CodeViewer(
          initialText: pretty,
          language: CodeLanguages.json,
          readOnly: true,
          maxLines: null,
          expands: true,
        ),
      ),
      actions: [
        if (onOpenInNewTab != null)
          TextButton.icon(
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open in new tab'),
            onPressed: () {
              onOpenInNewTab!();
              Navigator.of(context).pop();
            },
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Open a modal editor for a JSON value. Returns the compact-JSON
/// string the user committed, or `null` if they cancelled. Use this
/// instead of inline ColumnInput for `json`/`jsonb` cells — the
/// inline form needs 60-80 px of vertical space and the grid row is
/// 32 px fixed.
///
/// On open: the current value is pretty-printed (2-space indent).
/// On save: the textarea contents are validated and minified.
Future<String?> showJsonEditorDialog(
  BuildContext context, {
  required String columnName,
  required String currentValue,
}) async {
  // Picks the right host automatically: desktop spawns a real OS
  // window via desktop_multi_window; web falls back to a Material
  // dialog (no OS-window API in a browser tab).
  final raw = await openCodeEditor(
    context,
    title: columnName,
    initialText: _pretty(currentValue),
    language: CodeLanguages.json,
    validator: _validateJson,
    // Format button: pretty-print in place (visual).
    formatter: _pretty,
    formatLabel: 'Format',
  );
  // On commit, minify before handing back to the row update path.
  return raw == null ? null : compactJson(raw);
}

String _pretty(String input) {
  if (input.isEmpty) return input;
  try {
    return const JsonEncoder.withIndent(' ').convert(jsonDecode(input));
  } catch (_) {
    return input;
  }
}

String? _validateJson(String text) {
  if (text.isEmpty) return null;
  try {
    jsonDecode(text);
    return null;
  } catch (e) {
    return 'Invalid JSON: $e';
  }
}
