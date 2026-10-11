// The Windows 95 theme lives in the shared `widgets` package so apps outside
// dbscope (the compledo admin tool) can use it without depending on the
// dbscope app. Re-exported here so this plugin's API is unchanged.
export 'package:widgets/widgets.dart' show buildWin95Theme, win95Palette, Win95Theme;
