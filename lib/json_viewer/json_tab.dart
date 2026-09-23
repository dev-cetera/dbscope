import '../tabs/tab_model.dart';

/// Standalone viewer for a single JSON value (a cell value pulled out
/// of a grid). The viewer is detachable into its own tab when a user
/// wants to keep the JSON visible while continuing to browse rows.
class JsonTab extends TabModel {
  final String columnName;
  final String content;

  JsonTab({
    super.id,
    required super.connectionId,
    required this.columnName,
    required this.content,
  });

  @override
  String get title => 'JSON: $columnName';
}
