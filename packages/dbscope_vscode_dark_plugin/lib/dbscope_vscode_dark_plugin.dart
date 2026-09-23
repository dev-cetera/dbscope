import 'package:dbscope/plugins/dbscope_plugin.dart';
import 'package:dbscope/shell/theme_registry.dart';

import 'src/theme.dart';

export 'src/theme.dart'
    show buildVsCodeDarkTheme, vsCodeDarkPalette, VsCodeDarkTheme;

class VsCodeDarkThemePlugin extends DbscopePlugin {
  @override
  String get id => 'vsCodeDark';
  @override
  String get label => 'VS Code Dark Modern';

  @override
  void register(DbscopeHost host) {
    host.themes.register(
      const ThemePlugin(
        id: 'vsCodeDark',
        label: 'VS Code Dark Modern',
        build: buildVsCodeDarkTheme,
      ),
    );
  }
}
