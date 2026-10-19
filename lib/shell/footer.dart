import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../connection/registry.dart';
import '../tabs/tab_kind.dart';
import 'app_state.dart';
import 'shell_listenable.dart';

class Footer extends StatelessWidget {
  const Footer({super.key});

  /// Inserted as `const` under the shell, so a parent rebuild skips it —
  /// it subscribes itself.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: shellListenable,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final state = AppState.instance;
    final tab = state.active;
    final running = state.runningTabs().toList();
    final registry = ConnectionRegistry.instance;

    var left = '—';
    if (tab != null) {
      final summary = TabKindRegistry.instance.lookupForTab(tab)?.footerSummary?.call(tab);
      if (summary != null) left = summary;
    }

    return AppBevel(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 2.0),
      child: SizedBox(
        height: 22.0,
        child: SelectionArea(
          child: Row(
            children: [
              Expanded(
                child: AppBevel(
                  raised: false,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6.0,
                    vertical: 2.0,
                  ),
                  child: Text(left, style: palette.smallText),
                ),
              ),
              const SizedBox(width: 6.0),
              if (registry.profile?.readOnly ?? false)
                AppBevel(
                  raised: false,
                  color: palette.surface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6.0,
                    vertical: 2.0,
                  ),
                  child: Text(
                    'READ-ONLY',
                    style: palette.boldText.copyWith(fontSize: 10.0),
                  ),
                ),
              if (running.isNotEmpty) ...[
                const SizedBox(width: 6.0),
                ElevatedButton.icon(
                  icon: const Icon(Icons.stop_circle_outlined, size: 14.0),
                  label: Text('Cancel (${running.length})'),
                  style: ElevatedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8.0,
                      vertical: 2.0,
                    ),
                    visualDensity: VisualDensity.compact,
                    textStyle: palette.smallText,
                  ),
                  onPressed: () async {
                    state.cancelAll();
                    final activeId = registry.activeId;
                    if (activeId != null) {
                      await registry.killConnection(activeId);
                      if (!context.mounted) return;
                      await registry.connectActive(context: context);
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
