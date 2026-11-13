// One-shot LLM helper: given a column (with its position in the schema
// and a sample value), return a concise explanation of what the column
// represents.
//
// Used by the property inspector's right-click "AI Info" action — the
// user is staring at an opaque value like `MZ4-91X-22A` and wants a
// human-readable take on what it is. The model gets the DBML schema so
// it can use FK relationships and neighbouring columns to disambiguate.

import '../catalog/dbml_cache.dart';
import '../meta/meta_cache.dart';
import '../meta/meta_models.dart';
import 'ai_target.dart';
import 'sql_assistant.dart' show AssistantException;

class FieldExplainer {
  /// Returns a short, one-or-two-sentence explanation of the column.
  /// Throws [AssistantException] on configuration / AI errors so the
  /// caller can surface the message in the UI.
  static Future<String> explain({
    required String connectionId,
    required String schema,
    required String table,
    required String column,
    required String typeName,
    required Object? currentValue,
  }) async {
    final policy = MetadataCache.instance.snapshotFor(connectionId)?.policy;
    if (policy != null && !policy.can(Capability.ai)) {
      throw const AssistantException(
        'Your role on this connection cannot use AI features.',
      );
    }
    final target = await AiTarget.resolve();
    final status = DbmlCache.instance.statusFor(connectionId);
    if (status == DbmlStatus.pending) {
      // Block until the warm finishes; otherwise we'd answer with no
      // schema context and produce a worse explanation.
      final pending = DbmlCache.instance.pendingFuture(connectionId);
      if (pending != null) await pending;
    }
    final dbml = DbmlCache.instance.peek(connectionId);

    final valuePreview = _previewValue(currentValue);
    const system =
        'You are a database concierge. Given a DBML schema '
        'and one specific column, explain in 1-2 short sentences what '
        'that column represents and (if helpful) what the current value '
        'likely means. Be concrete; cite related tables/columns from '
        "the schema if they clarify the meaning. If you genuinely can't "
        'tell, say so briefly. No markdown, no headings, no preamble.';
    final user = StringBuffer()
      ..writeln('Table: "$schema"."$table"')
      ..writeln('Column: $column ($typeName)')
      ..writeln('Current value: $valuePreview')
      ..writeln()
      ..writeln(
        dbml != null && dbml.isNotEmpty
            ? 'Schema (DBML):\n$dbml'
            : '(Schema not available — answer from the column name alone.)',
      );

    final raw = await target.broker.complete(
      apiKey: target.apiKey,
      model: target.model,
      system: system,
      user: user.toString(),
    );
    return raw.trim();
  }

  static const _kMaxPreviewLength = 200;

  static String _previewValue(Object? value) {
    if (value == null) return 'NULL';
    var text = value is String ? value : value.toString();
    if (text.length > _kMaxPreviewLength) {
      text = '${text.substring(0, _kMaxPreviewLength)}…';
    }
    return text;
  }
}
