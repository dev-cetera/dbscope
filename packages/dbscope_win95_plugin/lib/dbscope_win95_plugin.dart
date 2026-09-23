import 'package:dbscope/plugins/dbscope_plugin.dart';
import 'package:dbscope/shell/theme_registry.dart';

import 'src/theme.dart';

export 'src/theme.dart' show buildWin95Theme, win95Palette, Win95Theme;

class Win95ThemePlugin extends DbscopePlugin {
  @override
  String get id => 'win95';
  @override
  String get label => 'Windows 95';

  @override
  void register(DbscopeHost host) {
    host.themes.register(
      const ThemePlugin(
        id: 'win95',
        label: 'Windows 95',
        build: buildWin95Theme,
      ),
    );
  }
}
