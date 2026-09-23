// Conditional facade for the code editor popup.
//
// On desktop (`dart:io`) we spawn a real `desktop_multi_window` subwindow
// running a single CodeEditorPanel — the user can drag the window
// independently and keep the host window working while editing. On web
// we fall back to a Material dialog hosted in the same browser tab.
//
// Same single entry point either way: `openCodeEditor(...)` returns the
// saved text or null if cancelled.

export 'code_editor_launcher_io.dart'
    if (dart.library.js_interop) 'code_editor_launcher_web.dart';
