// The VS Code Dark Modern themes live in the shared `widgets` package so apps
// outside dbscope (the compledo admin tool) can use them without depending on
// the dbscope app. Re-exported here so this plugin's API is unchanged.
export 'package:widgets/widgets.dart'
    show
        VsCodeDarkTheme,
        VsCodeOrangeTheme,
        buildVsCodeDarkTheme,
        buildVsCodeOrangeTheme,
        vsCodeDarkPalette,
        vsCodeOrangePalette;
