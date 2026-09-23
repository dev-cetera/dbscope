import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgets/widgets.dart';

import 'json_tab.dart';

/// Renders a single JSON value (typically detached from a grid cell)
/// as syntax-highlighted, scrollable text. The content is final — the
/// tab is read-only.
class JsonTabView extends StatelessWidget {
  final JsonTab tab;
  const JsonTabView({super.key, required this.tab});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final spans = highlightJson(tab.content, palette);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          titleIcon: Icons.data_object,
          title: tab.columnName,
          subtitle: 'JSON',
          trailing: IconButton(
            tooltip: 'Copy JSON',
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: tab.content));
              if (context.mounted) showToast(context, 'Copied to clipboard');
            },
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Container(
            color: palette.field,
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              child: SelectableText.rich(
                TextSpan(children: spans),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
