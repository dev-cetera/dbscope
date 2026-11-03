import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'crash_log.dart';

export 'crash_log.dart' show crashLogFolder, crashLogPath;

/// Routes every error nothing else caught into one place: the console and,
/// on desktop, the crash log ([crashLogPath]). Call once per isolate, first
/// thing in `main`.
///
/// Without this, an uncaught async error in a release build vanishes and a
/// widget that throws while building paints a blank grey box, so a user has
/// nothing to put in a bug report.
void installErrorHandlers({required String isolateLabel}) {
  final presentError = FlutterError.onError;
  FlutterError.onError = (details) {
    presentError?.call(details);
    recordError(
      details.exception,
      details.stack,
      context: details.context?.toDescription() ?? 'Flutter framework',
      isolateLabel: isolateLabel,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    recordError(error, stack, context: 'uncaught async error', isolateLabel: isolateLabel);
    // Handled: keep the app running. One failed background task must not
    // take every open tab down with it.
    return true;
  };
  if (kReleaseMode) {
    ErrorWidget.builder = (details) => const _BrokenWidgetPlaceholder();
  }
}

/// Writes one error to the crash log. Public so code that catches an error
/// it can't show anywhere can still leave a trace.
void recordError(
  Object error,
  StackTrace? stack, {
  required String context,
  String isolateLabel = '',
}) {
  final when = DateTime.now().toIso8601String();
  final where = isolateLabel.isEmpty ? '' : ' [$isolateLabel]';
  appendCrashLog('--- $when$where $context\n$error\n${stack ?? ''}\n');
}

/// Shown in place of a widget that threw while building, in release builds.
/// Depends on nothing inherited (no Theme, no Directionality), because the
/// subtree it replaces may be the one that provides them.
class _BrokenWidgetPlaceholder extends StatelessWidget {
  const _BrokenWidgetPlaceholder();

  @override
  Widget build(BuildContext context) {
    final log = crashLogPath();
    return ColoredBox(
      color: const Color(0x14FF0000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            log == null
                ? 'Something went wrong showing this part of dbscope.'
                : 'Something went wrong showing this part of dbscope. Details: $log',
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 12.0, color: Color(0xFFCC4444)),
          ),
        ),
      ),
    );
  }
}
