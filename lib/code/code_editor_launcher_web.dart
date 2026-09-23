// Web build of openCodeEditor. There are no OS-level windows in a
// browser tab, so the editor opens as a Material dialog in the same
// page — identical UX to the IO subwindow's body, just hosted in a
// different shell.

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

/// Open the code editor and return the saved text (or null on cancel).
///
/// The [validator] and [formatter] hooks mirror [showCodeEditorDialog]:
/// the validator gates the Save button, the formatter drives the Format
/// button (in-place pretty-print). On commit, the host is expected to
/// minify or otherwise transform the returned text — the dialog returns
/// the user's verbatim input.
Future<String?> openCodeEditor(
  BuildContext context, {
  required String title,
  required String initialText,
  required String language,
  CodeValidator? validator,
  CodeFormatter? formatter,
  String? saveLabel,
  String? cancelLabel,
  String? formatLabel,
}) {
  return showCodeEditorDialog(
    context,
    title: title,
    initialText: initialText,
    language: language,
    validator: validator,
    formatter: formatter,
    saveLabel: saveLabel,
    cancelLabel: cancelLabel,
    formatLabel: formatLabel,
  );
}
