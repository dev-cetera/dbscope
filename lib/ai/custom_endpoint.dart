import 'provider.dart';

/// Provider id of the user's own OpenAI-compatible endpoint
/// ([AiSettings.customBaseUrl]). Also its keychain slot.
const kCustomEndpointId = 'openai_compatible';

/// Registers the broker for [settings]'s custom endpoint, replaces it when
/// the URL changed, or removes it when the URL was cleared. Called wherever
/// settings are loaded or saved, so the registry always matches them.
void syncCustomEndpoint(AiSettings settings) {
  final registry = AiBrokerRegistry.instance;
  final url = settings.customBaseUrl;
  if (url == null) {
    registry.unregister(kCustomEndpointId);
    return;
  }
  final current = registry.lookup(kCustomEndpointId);
  if (current is OpenAiCompatibleBroker && current.baseUrl == _withoutTrailingSlash(url)) return;
  registry.register(
    OpenAiCompatibleBroker(
      id: kCustomEndpointId,
      label: 'OpenAI-compatible (${Uri.tryParse(url)?.host ?? url})',
      baseUrl: url,
    ),
  );
}

String _withoutTrailingSlash(String url) => url.endsWith('/') ? url.substring(0, url.length - 1) : url;
