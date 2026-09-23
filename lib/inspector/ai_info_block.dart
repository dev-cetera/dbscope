import 'package:flutter/material.dart';

import '../ai/field_explainer.dart';

/// Holds the lifecycle of a single "AI Info" request for a property
/// field. The property inspector creates one of these per field row and
/// listens for changes — the row UI stays declarative, the IO + state
/// transitions live here.
class AiInfoController extends ChangeNotifier {
  String? _info;
  bool _loading = false;

  String? get info => _info;
  bool get isLoading => _loading;
  bool get isVisible => _loading || _info != null;

  /// Kick off an explanation request. Replaces any previous state.
  Future<void> request({
    required String connectionId,
    required String schema,
    required String table,
    required String column,
    required String typeName,
    required Object? currentValue,
  }) async {
    _loading = true;
    _info = null;
    notifyListeners();
    try {
      final explanation = await FieldExplainer.explain(
        connectionId: connectionId,
        schema: schema,
        table: table,
        column: column,
        typeName: typeName,
        currentValue: currentValue,
      );
      _loading = false;
      _info = explanation;
    } catch (e) {
      _loading = false;
      _info = '$e';
    }
    notifyListeners();
  }

  void dismiss() {
    if (_info == null && !_loading) return;
    _info = null;
    _loading = false;
    notifyListeners();
  }
}

/// Inline panel under a property field showing either a "Thinking…"
/// spinner or the AI's explanation. Tightly bound to [AiInfoController]
/// but decoupled from any concrete data fetcher.
class AiInfoBlock extends StatelessWidget {
  final AiInfoController controller;
  const AiInfoBlock({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        if (!controller.isVisible) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(top: 4, bottom: 2),
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.auto_awesome,
                size: 13,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: controller.isLoading
                    ? _ThinkingRow(hint: theme.hintColor)
                    : SelectableText(
                        controller.info ?? '',
                        style: theme.textTheme.bodySmall,
                      ),
              ),
              if (!controller.isLoading)
                InkWell(
                  onTap: controller.dismiss,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4, top: 1),
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: theme.hintColor,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  final Color hint;
  const _ThinkingRow({required this.hint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(
          'Thinking…',
          style: theme.textTheme.bodySmall?.copyWith(color: hint),
        ),
      ],
    );
  }
}
