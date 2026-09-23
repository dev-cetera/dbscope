import 'package:dbscope/plugins/dbscope_plugin.dart';
import 'package:dbscope/shell/theme_registry.dart';

import 'src/theme.dart';

export 'src/theme.dart' show buildPortalTheme, portalPalette, PortalTheme;

class PortalThemePlugin extends DbscopePlugin {
  @override
  String get id => 'portal';
  @override
  String get label => 'Portal';

  @override
  void register(DbscopeHost host) {
    host.themes.register(
      const ThemePlugin(id: 'portal', label: 'Portal', build: buildPortalTheme),
    );
  }
}
