// Payload exchanged between the host and a code-editor subwindow.
//
// Travels twice: host → subwindow as the `launchPayload` JSON parsed in
// `main.dart`'s subwindow branch, and subwindow → host as the body of
// the `code_editor.commit` method call when the user saves. Lives in a
// pure Dart file so both isolates can share the same shape without
// pulling in any UI dependencies.

import 'dart:convert';

/// Discriminator stored at the top of the subwindow launch payload so
/// the new isolate knows it should run the code-editor UI instead of
/// the full DBScope shell.
const String codeEditorPayloadKind = 'code_editor';

/// Launch payload for a code-editor subwindow.
class CodeEditorLaunchPayload {
  const CodeEditorLaunchPayload({
    required this.requestId,
    required this.title,
    required this.initialText,
    required this.language,
    required this.themeId,
    this.saveLabel = 'Save',
    this.cancelLabel = 'Cancel',
    this.formatLabel,
    this.formatJson = false,
  });

  /// Unique id matching one [Completer] on the host side. Subwindow
  /// echoes it back in the commit / cancel message.
  final String requestId;

  /// Window title and the AlertDialog title on web.
  final String title;

  /// Initial text shown to the user.
  final String initialText;

  /// Language id understood by the shared `GrammarRegistry.defaults`.
  final String language;

  /// Theme id (matches `AppState.themeId`) — forwarded so the
  /// subwindow's chrome matches the host's.
  final String themeId;

  final String saveLabel;
  final String cancelLabel;

  /// Label for the Format button. When null the button is hidden.
  final String? formatLabel;

  /// When true, the editor exposes a JSON pretty-print as the format
  /// action and validates input as JSON. Generic enough to extend with
  /// other language modes later without changing the wire format.
  final bool formatJson;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': codeEditorPayloadKind,
    'requestId': requestId,
    'title': title,
    'initialText': initialText,
    'language': language,
    'themeId': themeId,
    'saveLabel': saveLabel,
    'cancelLabel': cancelLabel,
    if (formatLabel != null) 'formatLabel': formatLabel,
    'formatJson': formatJson,
  };

  factory CodeEditorLaunchPayload.fromJsonString(String source) {
    final raw = jsonDecode(source);
    if (raw is! Map) {
      throw const FormatException('CodeEditorLaunchPayload: not a JSON object');
    }
    return CodeEditorLaunchPayload(
      requestId: (raw['requestId'] as String?) ?? '',
      title: (raw['title'] as String?) ?? 'Edit',
      initialText: (raw['initialText'] as String?) ?? '',
      language: (raw['language'] as String?) ?? 'json',
      themeId: (raw['themeId'] as String?) ?? '',
      saveLabel: (raw['saveLabel'] as String?) ?? 'Save',
      cancelLabel: (raw['cancelLabel'] as String?) ?? 'Cancel',
      formatLabel: raw['formatLabel'] as String?,
      formatJson: raw['formatJson'] == true,
    );
  }

  /// True when [source] is a JSON object whose `kind` field marks it as
  /// a code-editor payload.
  static bool isCodeEditorPayload(String source) {
    if (source.isEmpty) return false;
    try {
      final raw = jsonDecode(source);
      return raw is Map && raw['kind'] == codeEditorPayloadKind;
    } catch (_) {
      return false;
    }
  }
}

/// Method name used by the subwindow to ship the saved text back to the
/// host via `DesktopMultiWindow.invokeMethod`. Wire shape:
/// `{ requestId: <id>, text: <savedText>?, cancelled: <bool> }`.
const String codeEditorCommitMethod = 'code_editor.commit';
