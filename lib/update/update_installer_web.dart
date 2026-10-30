import 'package:url_launcher/url_launcher.dart';

import 'update_source.dart';

/// Reloads the page onto the newly deployed bundle. Every hosted file is
/// served `Cache-Control: no-cache` (firebase.json), so the reload
/// revalidates and picks up the new `main.dart.js`.
Future<void> reloadPage() => launchUrl(Uri.base, webOnlyWindowName: '_self');

/// Web never installs a native build.
Future<void> installMacosUpdate(MacosRelease release, void Function(String stage) onStage) =>
    throw UnsupportedError('installMacosUpdate is macOS-only.');
