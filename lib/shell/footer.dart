import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../connection/registry.dart';
import '../tabs/tab_kind.dart';
import 'app_state.dart';

class Footer extends StatelessWidget {
  const Footer({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final state = AppState.instance;
    final tab = state.active;
    final running = state.runningTabs().toList();
    final registry = ConnectionRegistry.instance;

    String left = '—';
    if (tab != null) {
      final summary = TabKindRegistry.instance
          .lookupForTab(tab)
          ?.footerSummary
          ?.call(tab);
      if (summary != null) left = summary;
    }

    return AppBevel(
      raised: true,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: SizedBox(
        height: 22,
        child: SelectionArea(
          child: Row(
            children: [
              Expanded(
                child: AppBevel(
                  raised: false,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(left, style: palette.smallText),
                ),
              ),
              const SizedBox(width: 6),
              if (registry.profile?.readOnly == true)
                AppBevel(
                  raised: false,
                  color: palette.surface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    'READ-ONLY',
                    style: palette.boldText.copyWith(fontSize: 10),
                  ),
                ),
              if (running.isNotEmpty) ...[
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  icon: const Icon(Icons.stop_circle_outlined, size: 14),
                  label: Text('Cancel (${running.length})'),
                  style: ElevatedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
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
