// AI provider surface.
//
// Concrete providers and the registry live in `package:ai_broker`. This
// file only owns dbscope-specific state: persisted [AiSettings] (which
// provider is active, which model, the allowSampleRows flag, the custom
// endpoint — kept in the project document, separate from the API keys in
// SecureStore).

/// @docImport 'settings_store.dart';
library;

export 'package:ai_broker/ai_broker.dart'
    show
        AiAbortedException,
        AiBroker,
        AiBrokerException,
        AiBrokerRegistry,
        AiCompletion,
        AiFinishReason,
        AiKeyCheck,
        AiKeyStatus,
        AiMessage,
        AiRole,
        AiTool,
        AiToolCall,
        ChatBroker,
        ChatRequest,
        KeyCheckBroker,
        OpenAiCompatibleBroker,
        stripCodeFence;

/// User-visible AI configuration. Persisted via [AiSettingsStore]; API
/// keys live in SecureStore and are merged in at consumption time.
class AiSettings {
  const AiSettings({
    this.providerId,
    this.model,
    this.allowSampleRows = false,
    this.customBaseUrl,
  });

  factory AiSettings.fromJson(Map<String, Object?> json) => AiSettings(
    providerId: json['providerId'] as String?,
    model: json['model'] as String?,
    allowSampleRows: json['allowSampleRows'] as bool? ?? false,
    customBaseUrl: json['customBaseUrl'] as String?,
  );

  /// Active provider id. Null when nothing is configured yet.
  final String? providerId;

  /// Active model id within the active provider. Null when the user
  /// hasn't picked one (or the provider returns an empty list).
  final String? model;

  /// Whether the user has opted in to sending sample row values to the
  /// regex inferrer and to the agent's query results. Off by default —
  /// sample rows are real customer data and might be sensitive.
  final bool allowSampleRows;

  /// Base URL of an OpenAI-compatible API (a local Ollama or LM Studio, a
  /// gateway), everything before `/chat/completions`. Null when unused.
  /// When set, it shows up as one more provider; see `custom_endpoint.dart`.
  final String? customBaseUrl;

  AiSettings copyWith({
    String? providerId,
    String? model,
    bool? allowSampleRows,
    String? customBaseUrl,
  }) => AiSettings(
    providerId: providerId ?? this.providerId,
    model: model ?? this.model,
    allowSampleRows: allowSampleRows ?? this.allowSampleRows,
    customBaseUrl: customBaseUrl ?? this.customBaseUrl,
  );

  Map<String, Object?> toJson() => {
    if (providerId != null) 'providerId': providerId,
    if (model != null) 'model': model,
    'allowSampleRows': allowSampleRows,
    if (customBaseUrl != null) 'customBaseUrl': customBaseUrl,
  };
}
