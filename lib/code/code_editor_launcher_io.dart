// Desktop build of openCodeEditor. Spawns a real OS window via
// `desktop_multi_window` running a single CodeEditorPanel, then awaits
// a one-shot reply on the `code_editor.commit` method channel.
//
// Why a subwindow: editing a JSON blob is a focused task that should
// not block the rest of the app behind a modal. The user can keep
// scrolling the grid in the host window while the editor sits on
// top. Mirrors the rest of dbscope's multi-window architecture
// (host = window 0, subwindows talk via desktop_multi_window).

import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import '../shell/app_state.dart';
import 'code_editor_payload.dart';

/// Per-process handler installed on first call. Resolves the Completer
/// matching the request id when a subwindow commits or cancels. Kept as
/// a module-level singleton because `desktop_multi_window` only supports
/// a single method handler per isolate.
class _CodeEditorHostHub {
  _CodeEditorHostHub._() {
    DesktopMultiWindow.setMethodHandler(_handle);
  }
  static final _CodeEditorHostHub instance = _CodeEditorHostHub._();

  final Map<String, Completer<String?>> _pending =
      <String, Completer<String?>>{};

  Future<String?> awaitRequest(String requestId) {
    final completer = Completer<String?>();
    _pending[requestId] = completer;
    return completer.future;
  }

  Future<dynamic> _handle(MethodCall call, int fromWindowId) async {
    if (call.method != codeEditorCommitMethod) return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final id = args['requestId'];
    if (id is! String) return null;
    final completer = _pending.remove(id);
    if (completer == null) return null;
    if (args['cancelled'] == true) {
      completer.complete(null);
    } else {
      final text = args['text'];
      completer.complete(text is String ? text : null);
    }
    return null;
  }
}

/// Open the code editor in a new desktop window and return the saved
/// text (or null on cancel). [context] is accepted for API symmetry
/// with the web build but not used here.
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
}) async {
  // Touch the singleton so the method handler is installed exactly
  // once. Subsequent calls to `setMethodHandler` would replace the
  // existing handler — we want one shared handler that demuxes by
  // requestId across all pending editors.
  final hub = _CodeEditorHostHub.instance;
  final requestId = _generateRequestId();

  // `formatJson` is the only language-specific knob the subwindow needs
  // for now — the rest is plain text + validator. We don't ship the
  // validator function over the channel because it's a closure; the
  // subwindow re-derives it from `language` / `formatJson`.
  final isJson =
      formatter != null && language == 'json' ||
      validator != null && language == 'json';

  final payload = CodeEditorLaunchPayload(
    requestId: requestId,
    title: title,
    initialText: initialText,
    language: language,
    themeId: AppState.instance.themeId,
    saveLabel: saveLabel ?? 'Save',
    cancelLabel: cancelLabel ?? 'Cancel',
    formatLabel: formatLabel,
    formatJson: isJson,
  );

  final future = hub.awaitRequest(requestId);

  final controller = await DesktopMultiWindow.createWindow(
    jsonEncode(payload.toJson()),
  );
  await controller.setTitle(title);
  await controller.setFrame(_defaultFrame());
  await controller.show();

  return future;
}

Rect _defaultFrame() {
  // Anchor near the top-left of the screen with a sensible editor
  // shape. The user can move and resize from the OS chrome.
  return const Rect.fromLTWH(160, 160, 760, 540);
}

String _generateRequestId() {
  // Cheap, collision-resistant enough for the few editors that can be
  // open simultaneously. Avoids pulling in `package:uuid` just for this.
  final now = DateTime.now().microsecondsSinceEpoch;
  final rand = (now & 0xFFFFFF) ^ identityHashCode(_CodeEditorHostHub.instance);
  return 'code-editor-$now-${rand.toRadixString(16)}';
}
