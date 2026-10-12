/// Reusable Flutter UI primitives, theme-agnostic.
///
/// The shared [AppPalette] [ThemeExtension] holds role-based colors;
/// every chrome widget reads from `AppPalette.of(context)` and shape-
/// adapts via [ChromeKind] (bevel vs flat). Two concrete themes ship here
/// ([buildVsCodeDarkTheme], [buildWin95Theme]) so apps outside dbscope can
/// use them; dbscope's theme plugins re-export them and register them with
/// the host's `ThemeRegistry`.
///
/// Adaptive chrome widgets: [AppBevel], [AppButton], [AppToggleButton],
/// [AppFrame], [AppInset], [AppMenuBar] / [AppMenu] / [AppMenuItem],
/// [AppStatusBar], [AppTabBar] / [AppTab], [MetricChip].
///
/// @docImport 'package:flutter/material.dart';
/// @docImport 'src/themes/vscode_dark_theme.dart';
/// @docImport 'src/themes/win95_theme.dart';
library;

import 'widgets.dart'
    show
        AppBevel,
        AppButton,
        AppFrame,
        AppInset,
        AppMenu,
        AppMenuBar,
        AppMenuItem,
        AppStatusBar,
        AppTab,
        AppTabBar,
        AppToggleButton,
        ChromeKind,
        MetricChip;

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
export 'src/themes/vscode_dark_theme.dart';
export 'src/themes/win95_theme.dart';
export 'src/v_resizable.dart';
