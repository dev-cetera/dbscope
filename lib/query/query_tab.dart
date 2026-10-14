import '../grid/data_grid.dart';
import '../tabs/tab_model.dart';

/// Longest tab title (in characters) before it is cut with an ellipsis.
const _kTitleMaxLength = 40;

/// Unified query tab. Hosts both the SQL editor (manual) and the AI
/// prompt strip (collapsible). The same tab handles "ask AI → generate
/// SQL → edit → run" without spawning a sibling tab.
class QueryTab extends TabModel {
  QueryTab({
    super.id,
    required super.connectionId,
    this.sql = '',
    this.prompt = '',
    this.focusSchema,
    this.focusTable,
    this.historyRailOpen = false,
    this.data,
    this.isLoading = false,
    this.isAsking = false,
    this.error,
    this.elapsed,
    this.truncated = false,
    this.titleOverride,
    this.savedName,
    this.autoRun = false,
  });
  String sql;
  String prompt;
  String? focusSchema;
  String? focusTable;

  /// Persisted: whether the left history rail is expanded.
  bool historyRailOpen;

  /// Transient: AI request in flight. Not persisted.
  bool isAsking;

  GridData? data;
  bool isLoading;
  String? error;
  Duration? elapsed;
  bool truncated;
  String? titleOverride;
  String? savedName;
  GridViewMode viewMode = GridViewMode.typed;

  /// One-shot: when true, the view runs [sql] after the first frame and
  /// then clears the flag. Set when programmatically opening a tab that
  /// should produce a result immediately (e.g. inbound-FK link).
  bool autoRun;

  /// Row currently selected in the result grid, surfaced in the
  /// shared right-side inspector. Null when nothing is selected.
  int? selectedRowIndex;

  @override
  String get title {
    if (savedName != null && savedName!.isNotEmpty) return savedName!;
    if (titleOverride != null && titleOverride!.isNotEmpty) {
      return titleOverride!;
    }
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isNotEmpty) {
      return trimmedPrompt.length <= _kTitleMaxLength
          ? 'AI: $trimmedPrompt'
          : 'AI: ${trimmedPrompt.substring(0, _kTitleMaxLength)}…';
    }
    final trimmed = sql.trim();
    if (trimmed.isEmpty) return 'New query';
    if (trimmed.length <= _kTitleMaxLength) return trimmed;
    return '${trimmed.substring(0, _kTitleMaxLength)}…';
  }
}
