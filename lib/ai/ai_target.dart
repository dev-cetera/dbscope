import 'ai_key_resolver.dart';
import 'provider.dart';
import 'settings_store.dart';
import 'sql_assistant.dart' show AssistantException;

/// The chat broker, API key and model an AI feature sends to: what the user
/// picked in AI ▸ Settings…, resolved once per call. Every AI feature goes
/// through [resolve], so they all fail with the same messages.
class AiTarget {
  const AiTarget._({required this.broker, required this.apiKey, required this.model});

  final ChatBroker broker;
  final String apiKey;
  final String model;

  /// Resolves the active provider. Throws [AssistantException] when no
  /// provider is set, it's gone, it can't chat, it has no key, or it lists
  /// no models in "auto" mode.
  ///
  /// When no model is saved ("auto"), asks the provider for its list and
  /// takes the first: one extra round-trip per call, acceptable for features
  /// the user starts by hand.
  static Future<AiTarget> resolve([AiSettings? settings]) async {
    final active = settings ?? await AiSettingsStore.instance.load();
    final providerId = active.providerId;
    if (providerId == null) {
      throw const AssistantException(
        'No AI provider configured. Open AI ▸ Settings… first.',
      );
    }
    final registered = AiBrokerRegistry.instance.lookup(providerId);
    if (registered == null) {
      throw AssistantException('Provider "$providerId" no longer available.');
    }
    if (registered is! ChatBroker) {
      throw AssistantException('Provider "${registered.label}" cannot chat.');
    }
    final apiKey = await AiKeyResolver.resolve(providerId);
    if (apiKey.isEmpty && !AiKeyResolver.keyOptional(providerId)) {
      throw const AssistantException(
        'API key missing. Open AI ▸ Settings… and paste a key, or '
        'export it in your shell env file (File ▸ Environment…).',
      );
    }
    final model = active.model ?? await _firstModel(registered, apiKey);
    return AiTarget._(broker: registered, apiKey: apiKey, model: model);
  }

  static Future<String> _firstModel(ChatBroker broker, String apiKey) async {
    final models = await broker.listModels(apiKey);
    if (models.isEmpty) {
      throw const AssistantException(
        'Provider returned no models. Check the API key in AI ▸ Settings…',
      );
    }
    return models.first;
  }
}
