import 'package:key_flow/key_flow.dart';
import 'package:widgets/widgets.dart';

import 'app_commands.dart';
import 'shell_listenable.dart';
import 'ui_prefs.dart';

/// Behind key_flow's palette and sheets: dims the window without hiding it.
const _kScrim = Color(0x33000000);

/// The window's key_flow root: the app's commands as shortcuts, the menu bar
/// (native on macOS, drawn above [child] elsewhere), the command palette (⌘K),
/// the shortcut sheet (`?`, ⌘/), jump mode (⌘J) and F6 between the named
/// areas. Mounted in `MaterialApp.builder`, so it covers every route and
/// dialog.
///
/// Only this widget rebuilds on shell changes; [child] (the Navigator) is
/// passed through untouched. key_flow re-sends the native menu only when
/// what it shows changes, so a resize drag doesn't flood the platform
/// channel.
class AppKeyFlow extends StatefulWidget {
  const AppKeyFlow({super.key, required this.child});
  final Widget child;

  @override
  State<AppKeyFlow> createState() => _AppKeyFlowState();
}

class _AppKeyFlowState extends State<AppKeyFlow> {
  final _keys = KeyFlowController();
  Map<String, List<String>> _keyOverrides = UiPrefs.instance.keyOverrides;

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  void _onKeyOverridesChanged(Map<String, List<String>> overrides) {
    setState(() => _keyOverrides = overrides);
    UiPrefs.instance.setKeyOverrides(overrides);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final style = KeyFlowStyle(
      surface: palette.surfaceRaised,
      onSurface: palette.text,
      muted: palette.mutedText,
      accent: palette.accent,
      onAccent: palette.onAccent,
      keyCap: palette.surfaceRecessed,
      border: palette.borderStrong,
      scrim: _kScrim,
      radius: palette.cornerRadius,
      textStyle: TextStyle(
        color: palette.text,
        fontSize: palette.bodyFontSize,
        fontFamily: palette.uiFontFamily,
      ),
    );
    return ListenableBuilder(
      listenable: shellListenable,
      builder: (context, child) => KeyFlow(
        controller: _keys,
        commands: buildAppCommands(keys: _keys),
        keyOverrides: _keyOverrides,
        onKeyOverridesChanged: _onKeyOverridesChanged,
        style: style,
        child: child!,
      ),
      child: KeyFlowMenuBar(drawOnOtherPlatforms: true, child: widget.child),
    );
  }
}
