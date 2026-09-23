// Shell-level window actions. Hides the desktop_multi_window dependency
// from the menu code so we can adapt to a different transport later.

import 'dart:convert';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';

import '../connection/registry.dart';
import 'app_state.dart';

class WindowActions {
  WindowActions._();

  // Spawn a new DBScope window. If [profileId] is given the new window
  // will set that profile active on startup. The active theme is
  // always forwarded so the new window matches the current one
  // instead of falling back to the default.
  static Future<void> spawnWindow({String? profileId}) async {
    profileId ??= ConnectionRegistry.instance.activeId;
    final payload = jsonEncode(<String, Object?>{
      'profileId': ?profileId,
      'themeId': AppState.instance.themeId,
    });
    final controller = await DesktopMultiWindow.createWindow(payload);
    await controller.setTitle('DBScope');
    await controller.setFrame(_defaultFrame());
    await controller.show();
  }

  static Rect _defaultFrame() {
    // Anchor near top-left; user can move it. Real frame autosave would
    // be a follow-up.
    return const Rect.fromLTWH(120, 120, 1280, 800);
  }
}
