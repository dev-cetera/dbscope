/// Reusable Flutter UI primitives, theme-agnostic.
///
/// The shared [AppPalette] [ThemeExtension] holds role-based colors;
/// every chrome widget reads from `AppPalette.of(context)` and shape-
/// adapts via [ChromeKind] (bevel vs flat). Concrete palettes ship in
/// per-theme plugin packages (`packages/dbscope_*_plugin`) and register
/// themselves with the host's `ThemeRegistry`.
///
/// Adaptive chrome widgets: [AppBevel], [AppButton], [AppToggleButton],
/// [AppFrame], [AppInset], [AppMenuBar] / [AppMenu] / [AppMenuItem],
/// [AppStatusBar], [AppTabBar] / [AppTab], [MetricChip].
library;

export 'src/app_bevel.dart';
export 'src/app_button.dart';
export 'src/app_frame.dart';
export 'src/app_menubar.dart';
export 'src/app_statusbar.dart';
export 'src/app_tabs.dart';
export 'src/app_theme.dart';
export 'src/async_loader.dart';
export 'src/banner.dart';
export 'src/code_viewer.dart';
export 'src/context_menu.dart';
export 'src/feedback.dart';
export 'src/form_dialog.dart';
export 'src/json_highlight.dart';
export 'src/metric_chip.dart';
export 'src/palette.dart';
export 'src/panel.dart';
export 'src/resizable.dart';
export 'src/searchable_menu.dart';
export 'src/states.dart';
export 'src/v_resizable.dart';
