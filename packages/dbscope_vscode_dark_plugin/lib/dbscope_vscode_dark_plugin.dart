import 'package:dbscope/plugins/dbscope_plugin.dart';
import 'package:dbscope/shell/theme_registry.dart';

import 'src/theme.dart';

export 'src/theme.dart'
    show
        VsCodeDarkTheme,
        VsCodeOrangeTheme,
        buildVsCodeDarkTheme,
        buildVsCodeOrangeTheme,
        vsCodeDarkPalette,
        vsCodeOrangePalette;

/// Registers two VS Code Dark Modern themes: the dbscope orange variant
/// (registered first, so it is the app's default and fallback when this
/// plugin is registered first) and the original blue one.
class VsCodeDarkThemePlugin extends DbscopePlugin {
  @override
  String get id => 'vsCodeDark';
  @override
  String get label => 'VS Code Dark Modern';

  @override
  void register(DbscopeHost host) {
    host.themes.register(
      const ThemePlugin(
        id: 'vsCodeOrange',
        label: 'dbscope Orange',
        build: buildVsCodeOrangeTheme,
      ),
    );
    host.themes.register(
      const ThemePlugin(
        id: 'vsCodeDark',
        label: 'VS Code Dark Modern',
        build: buildVsCodeDarkTheme,
      ),
    );
  }
}
