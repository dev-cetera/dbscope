import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:widgets/widgets.dart';

import 'update_service.dart';
import 'update_source.dart';

/// Space kept clear under the prompt so it floats above the footer bar.
const _kFooterClearance = 30.0;
const _kPromptMaxWidth = 420.0;

/// The "new version" prompt: bottom-center on web (Refresh), bottom-right on
/// macOS (Install update). Mounted once in the host window's root stack and
/// listens to [UpdateService.status] itself, since the root doesn't rebuild.
class UpdatePrompt extends StatelessWidget {
  const UpdatePrompt({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: UpdateService.instance.status,
      builder: (context, status, _) {
        if (status is UpToDate) return const SizedBox.shrink();
        return Align(
          alignment: kIsWeb ? Alignment.bottomCenter : Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12.0, 12.0, 12.0, _kFooterClearance),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kPromptMaxWidth),
              // The root stack sits above the Navigator, so no Material yet.
              child: Material(
                type: MaterialType.transparency,
                child: AppFrame(child: _PromptBody(status: status)),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PromptBody extends StatelessWidget {
  const _PromptBody({required this.status});
  final UpdateStatus status;

  @override
  Widget build(BuildContext context) {
    final service = UpdateService.instance;
    return switch (status) {
      UpToDate() => const SizedBox.shrink(),
      UpdateReady(:final channel, :final version) => _PromptRow(
        message: channel == UpdateChannel.web
            ? 'A new version of dbscope ($version) is ready.'
            : 'dbscope $version is available.',
        actionLabel: channel == UpdateChannel.web ? 'Refresh' : 'Install update',
        onAction: () => unawaited(service.install()),
        onDismiss: service.dismiss,
      ),
      UpdateInstalling(:final stage) => _PromptRow(message: stage),
      UpdateFailed(:final message) => _PromptRow(
        message: message,
        actionLabel: 'Download manually',
        onAction: () => unawaited(
          launchUrl(ReleaseSource.releasesPage, mode: LaunchMode.externalApplication),
        ),
        onDismiss: service.dismiss,
      ),
    };
  }
}

class _PromptRow extends StatelessWidget {
  const _PromptRow({
    required this.message,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final label = actionLabel;
    final dismiss = onDismiss;
    return Row(
      children: [
        Expanded(
          child: Text(message, style: TextStyle(color: palette.text)),
        ),
        if (label != null) ...[
          const SizedBox(width: 8.0),
          AppButton(onPressed: onAction, child: Text(label)),
        ],
        if (dismiss != null) ...[
          const SizedBox(width: 4.0),
          AppButton(onPressed: dismiss, child: const Text('✕')),
        ],
      ],
    );
  }
}
