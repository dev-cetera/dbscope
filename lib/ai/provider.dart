// AI provider surface.
//
// Concrete providers and the registry live in `package:ai_broker`. This
// file only owns dbscope-specific state: persisted [AiSettings] (which
// provider is active, which model, the allowSampleRows flag — kept in
// SharedPreferences, separate from the API keys in SecureStore).

export 'package:ai_broker/ai_broker.dart'
    show
        AiBroker,
        AiBrokerException,
        AiBrokerRegistry,
        AiMessage,
        AiRole,
        ChatRequest;

/// User-visible AI configuration. Persisted via [AiSettingsStore]; API
/// keys live in SecureStore and are merged in at consumption time.
class AiSettings {
  /// Active provider id. Null when nothing is configured yet.
  final String? providerId;

  /// Active model id within the active provider. Null when the user
  /// hasn't picked one (or the provider returns an empty list).
  final String? model;

  /// Whether the user has opted in to sending sample row values to the
  /// regex inferrer. Off by default — sample rows are real customer data
  /// and might be sensitive.
  final bool allowSampleRows;

  const AiSettings({
    this.providerId,
    this.model,
    this.allowSampleRows = false,
  });

  AiSettings copyWith({
    String? providerId,
    String? model,
    bool? allowSampleRows,
  }) => AiSettings(
    providerId: providerId ?? this.providerId,
    model: model ?? this.model,
    allowSampleRows: allowSampleRows ?? this.allowSampleRows,
  );

  Map<String, Object?> toJson() => {
    if (providerId != null) 'providerId': providerId,
    if (model != null) 'model': model,
    'allowSampleRows': allowSampleRows,
  };

  static AiSettings fromJson(Map<String, Object?> json) => AiSettings(
    providerId: json['providerId'] as String?,
    model: json['model'] as String?,
    allowSampleRows: json['allowSampleRows'] as bool? ?? false,
  );
}
