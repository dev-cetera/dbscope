// The VS Code Dark Modern theme lives in the shared `widgets` package so apps
// outside dbscope (the compledo admin tool) can use it without depending on
// the dbscope app. Re-exported here so this plugin's API is unchanged.
export 'package:widgets/widgets.dart'
    show VsCodeDarkTheme, buildVsCodeDarkTheme, vsCodeDarkPalette;
