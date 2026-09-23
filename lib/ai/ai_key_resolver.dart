import '../connection/secure_store.dart';
import '../util/shell_env.dart';

/// Where an AI provider's API key comes from, in priority order:
///
///  1. the keychain, if the user pasted one in AI ▸ Settings…;
///  2. the provider's conventional env var, resolved through
///     [ShellEnv] — so a `GEMINI_API_KEY` already exported in
///     `~/.zshenv` works with nothing to configure.
///
/// The keychain wins because it's the explicit choice: a user who typed
/// a key into this app meant to use *that* key, even on a machine whose
/// shell exports a different one.
class AiKeyResolver {
  AiKeyResolver._();

  /// Conventional env var per provider id, following what each vendor's
  /// own SDK documents. Ids match `AiBroker.id`.
  static const Map<String, String> envVarNames = {
    'openai': 'OPENAI_API_KEY',
    'anthropic': 'ANTHROPIC_API_KEY',
    'gemini': 'GEMINI_API_KEY',
  };

  /// The key to use for [providerId], or empty when there is none.
  static Future<String> resolve(String providerId) async {
    final stored = await SecureStore.instance.readAiKey(providerId);
    if (stored != null && stored.isNotEmpty) return stored;
    return fromEnv(providerId) ?? '';
  }

  /// The env-var key alone, ignoring the keychain. Lets the settings
  /// dialog tell the user "nothing pasted, but $GEMINI_API_KEY is
  /// covering you" instead of showing an empty field that looks broken.
  static String? fromEnv(String providerId) {
    final name = envVarNames[providerId];
    if (name == null) return null;
    final value = ShellEnv.instance.value(name);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The env var [providerId] would read, for UI copy. Null for a
  /// provider with no convention (a third-party broker plugin).
  static String? envVarNameFor(String providerId) => envVarNames[providerId];

  /// The key the app will actually use for [providerId] given what is
  /// currently TYPED into the settings field — the live-editing twin of
  /// [resolve], which reads the saved keychain value instead.
  ///
  /// Declared once because it is the rule that decides which key the
  /// assistant ends up sending, and the settings dialog asks it from two
  /// places (Verify, and the provider switch's model prefetch). Those two
  /// disagreeing would make Verify test a different key than the one the
  /// app then uses.
  static String effectiveKey(String providerId, String typed) {
    final trimmed = typed.trim();
    return trimmed.isEmpty ? (fromEnv(providerId) ?? '') : trimmed;
  }
}
