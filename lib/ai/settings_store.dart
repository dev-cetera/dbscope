import '../project/project_store.dart';
import 'provider.dart';

/// Thin facade over [ProjectStore]: AI settings (active provider, model,
/// sample-rows opt-in) live inside the project's `.dbscopeproj` document.
/// API keys do not — they're in SecureStore via the keychain.
class AiSettingsStore {
  AiSettingsStore._();
  static final AiSettingsStore instance = AiSettingsStore._();

  Future<AiSettings> load() async {
    final doc = await ProjectStore.instance.load();
    return doc.ai;
  }

  Future<void> save(AiSettings settings) =>
      ProjectStore.instance.setAiSettings(settings);
}
