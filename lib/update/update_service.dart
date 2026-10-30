import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'update_installer.dart';
import 'update_source.dart';

/// Where newer builds come from: the web deploy's `version.json`, or the
/// latest GitHub release for the macOS app.
enum UpdateChannel { web, macos }

/// What the update prompt shows. One state at a time, so the prompt can't
/// show "installing" and "failed" together.
sealed class UpdateStatus {
  const UpdateStatus();
}

class UpToDate extends UpdateStatus {
  const UpToDate();
}

/// A newer build exists. [release] is set on the macOS channel only.
class UpdateReady extends UpdateStatus {
  const UpdateReady(this.channel, this.version, {this.release});
  final UpdateChannel channel;
  final AppVersion version;
  final MacosRelease? release;
}

class UpdateInstalling extends UpdateStatus {
  const UpdateInstalling(this.stage);
  final String stage;
}

class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.message);
  final String message;
}

/// Checks for a newer build and installs it.
///
/// Web: polls `version.json` (written by `flutter build web` from the
/// `--build-name`/`--build-number` CI passes) every 15 minutes; installing
/// means reloading the page. macOS: polls GitHub's latest release every 6
/// hours (GitHub allows 60 unauthenticated calls an hour); installing means
/// [installMacosUpdate] + quitting so the helper can swap and relaunch.
///
/// Runs only when the build carries a version stamp ([kRunningVersionStamp]);
/// a local `flutter run` has nothing to compare against.
class UpdateService {
  UpdateService._();
  static final instance = UpdateService._();

  static const _kWebPollInterval = Duration(minutes: 15);
  static const _kMacosPollInterval = Duration(hours: 6);
  static const _kRequestTimeout = Duration(seconds: 10);

  final ValueNotifier<UpdateStatus> status = ValueNotifier(const UpToDate());

  Timer? _timer;
  AppVersion? _dismissed;

  /// Starts polling. Call once, from the host window only.
  void start() {
    final running = AppVersion.tryParse(kRunningVersionStamp);
    if (running == null) {
      debugPrint('UpdateService: no APP_VERSION stamp ("$kRunningVersionStamp"); update checks off.');
      return;
    }
    final channel = _channelForPlatform();
    if (channel == null) return;
    final interval = channel == UpdateChannel.web ? _kWebPollInterval : _kMacosPollInterval;
    unawaited(_check(channel, running));
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_check(channel, running)));
  }

  /// Hides the prompt until a version newer than the one shown appears.
  void dismiss() {
    final current = status.value;
    if (current is UpdateReady) _dismissed = current.version;
    status.value = const UpToDate();
  }

  /// Applies the update [status] currently offers.
  Future<void> install() async {
    final current = status.value;
    if (current is! UpdateReady) return;
    switch (current.channel) {
      case UpdateChannel.web:
        await reloadPage();
      case UpdateChannel.macos:
        await _installMacos(current.release!);
    }
  }

  Future<void> _installMacos(MacosRelease release) async {
    _timer?.cancel();
    try {
      await installMacosUpdate(release, (stage) => status.value = UpdateInstalling(stage));
    } on UpdateInstallException catch (e) {
      status.value = UpdateFailed(e.message);
      return;
    } on Exception catch (e) {
      debugPrint('UpdateService: install failed: $e');
      status.value = UpdateFailed('The update failed: $e');
      return;
    }
    // The helper swaps the bundle once this process is gone. A cancelable
    // exit runs the host's quit hook first (saves tabs, closes connections).
    await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
  }

  UpdateChannel? _channelForPlatform() {
    if (kIsWeb) return UpdateChannel.web;
    if (defaultTargetPlatform == TargetPlatform.macOS) return UpdateChannel.macos;
    // Windows and Linux have no published builds to update to.
    return null;
  }

  Future<void> _check(UpdateChannel channel, AppVersion running) async {
    if (status.value is UpdateInstalling) return;
    try {
      final UpdateReady offer;
      switch (channel) {
        case UpdateChannel.web:
          offer = UpdateReady(channel, await _latestWebVersion());
        case UpdateChannel.macos:
          final release = await _latestMacosRelease();
          offer = UpdateReady(channel, release.version, release: release);
      }
      final dismissed = _dismissed;
      final isNew = offer.version.isNewerThan(running);
      final wasDismissed = dismissed != null && !offer.version.isNewerThan(dismissed);
      if (isNew && !wasDismissed) status.value = offer;
    } on Exception catch (e) {
      // Offline, rate-limited or mid-deploy: the next poll tries again.
      debugPrint('UpdateService: check failed: $e');
    }
  }

  Future<AppVersion> _latestWebVersion() async {
    // The root copy, not the one beside this build: deployed builds live in
    // per-deploy folders (/b/<run>/, scripts/stage_web_build.sh), and a tab's
    // own folder never sees a newer version. Cache-busted so neither the
    // browser nor a CDN edge answers for the origin.
    final url = Uri.base.resolve('/version.json').replace(
      queryParameters: {'_': '${DateTime.now().millisecondsSinceEpoch}'},
    );
    final json = await _getJson(url);
    return parseVersionJson(json);
  }

  Future<MacosRelease> _latestMacosRelease() async {
    final json = await _getJson(
      ReleaseSource.latestReleaseApi,
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    return parseGithubRelease(json);
  }

  Future<Map<String, Object?>> _getJson(Uri url, {Map<String, String>? headers}) async {
    final response = await http.get(url, headers: headers).timeout(_kRequestTimeout);
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', url);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw FormatException('$url did not return a JSON object');
    }
    return decoded;
  }
}
