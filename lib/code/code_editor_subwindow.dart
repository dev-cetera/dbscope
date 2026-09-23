// App that runs inside a code-editor subwindow. Spawned from
// `main.dart`'s subwindow branch when the launch payload is a
// `code_editor` kind. Renders a single CodeEditorPanel and ships the
// result back to the host via `DesktopMultiWindow.invokeMethod`.

import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../shell/theme_registry.dart';
import 'code_editor_payload.dart';

/// Top-level widget for a code-editor subwindow.
class CodeEditorSubwindowApp extends StatelessWidget {
  const CodeEditorSubwindowApp({
    super.key,
    required this.windowId,
    required this.payload,
  });

  final int windowId;
  final CodeEditorLaunchPayload payload;

  @override
  Widget build(BuildContext context) {
    // Match the host's theme so chrome and the syntax palette feel
    // continuous. Fall back to the first registered theme if the host's
    // id isn't known here (theme plugins are registered identically in
    // every isolate via `main.dart`'s _registerPlugins).
    final registry = ThemeRegistry.instance;
    final plugin = registry.lookup(payload.themeId) ?? registry.fallback;
    final themeData = plugin?.build();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: payload.title,
      theme: themeData,
      home: CodeEditorSubwindowScreen(
        windowId: windowId,
        payload: payload,
      ),
    );
  }
}

class CodeEditorSubwindowScreen extends StatefulWidget {
  const CodeEditorSubwindowScreen({
    super.key,
    required this.windowId,
    required this.payload,
  });

  final int windowId;
  final CodeEditorLaunchPayload payload;

  @override
  State<CodeEditorSubwindowScreen> createState() =>
      _CodeEditorSubwindowScreenState();
}

class _CodeEditorSubwindowScreenState extends State<CodeEditorSubwindowScreen> {
  final GlobalKey<CodeEditorPanelState> _panelKey =
      GlobalKey<CodeEditorPanelState>();
  bool _isValid = true;
  bool _replied = false;

  CodeValidator? get _validator =>
      widget.payload.formatJson ? _validateJson : null;

  CodeFormatter? get _formatter => widget.payload.formatLabel == null
      ? null
      : widget.payload.formatJson
      ? _prettyJson
      : _identity;

  static String? _validateJson(String text) {
    if (text.isEmpty) return null;
    try {
      jsonDecode(text);
      return null;
    } catch (e) {
      return 'Invalid JSON: $e';
    }
  }

  static String _prettyJson(String text) {
    if (text.isEmpty) return text;
    try {
      return const JsonEncoder.withIndent(' ').convert(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }

  static String _identity(String text) => text;

  Future<void> _reply({required bool cancelled, String? text}) async {
    if (_replied) return;
    _replied = true;
    await DesktopMultiWindow.invokeMethod(0, codeEditorCommitMethod, {
      'requestId': widget.payload.requestId,
      'text': text,
      'cancelled': cancelled,
    });
    // The window is dedicated to this single editor session — close it
    // as soon as the host has the result.
    await WindowController.fromWindowId(widget.windowId).close();
  }

  void _save() {
    final state = _panelKey.currentState;
    if (state == null || !state.isValid) return;
    _reply(cancelled: false, text: state.text);
  }

  void _cancel() => _reply(cancelled: true);

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(title: Text(widget.payload.title)),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: CodeEditorPanel(
          key: _panelKey,
          initialText: widget.payload.initialText,
          language: widget.payload.language,
          validator: _validator,
          formatter: _formatter,
          onChanged: (_) {
            final v = _panelKey.currentState?.isValid ?? true;
            if (v != _isValid) setState(() => _isValid = v);
          },
          onSaveRequested: (_) => _save(),
          onCancelRequested: _cancel,
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_formatter != null) ...[
                TextButton(
                  onPressed: () => _panelKey.currentState?.format(),
                  child: Text(widget.payload.formatLabel ?? 'Format'),
                ),
                const SizedBox(width: 8),
              ],
              TextButton(
                onPressed: _cancel,
                child: Text(widget.payload.cancelLabel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _isValid ? _save : null,
                child: Text(widget.payload.saveLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
