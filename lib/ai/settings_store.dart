import '../project/project_store.dart';
import 'custom_endpoint.dart';
import 'provider.dart';

/// Thin facade over [ProjectStore]: AI settings (active provider, model,
/// sample-rows opt-in) live inside the project's `.dbscopeproj` document.
/// API keys do not — they're in SecureStore via the keychain.
///
/// Loading and saving also keep the custom endpoint's broker registered to
/// match ([syncCustomEndpoint]), so no caller has to remember to.
class AiSettingsStore {
  AiSettingsStore._();
  static final instance = AiSettingsStore._();

  Future<AiSettings> load() async {
    final projectDocument = await ProjectStore.instance.load();
    syncCustomEndpoint(projectDocument.ai);
    return projectDocument.ai;
  }

  Future<void> save(AiSettings settings) async {
    syncCustomEndpoint(settings);
    await ProjectStore.instance.setAiSettings(settings);
  }
}
