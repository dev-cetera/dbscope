import 'package:ai_broker/ai_broker.dart' show EnvKeyResolver;

import '../connection/secure_store.dart';
import '../util/shell_env.dart';
import 'custom_endpoint.dart';

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
///
/// The user's own endpoint ([kCustomEndpointId]) is usually a local server
/// that takes no key, so it gets [kNoKeyPlaceholder] when none is set.
class AiKeyResolver {
  AiKeyResolver._();

  /// Sent to a keyless custom endpoint: brokers treat an empty key as "not
  /// configured" and skip the request, and local servers ignore the header.
  static const kNoKeyPlaceholder = 'no-key';

  /// ai_broker's resolver, reading through [ShellEnv] instead of the
  /// process environment, which a Finder-launched app barely has. Its
  /// [EnvKeyResolver.envVarNames] are the vendors' documented names.
  static final _env = EnvKeyResolver(lookup: ShellEnv.instance.value);

  /// The key to use for [providerId], or empty when there is none.
  static Future<String> resolve(String providerId) async {
    final stored = await SecureStore.instance.readAiKey(providerId);
    if (stored != null && stored.isNotEmpty) return stored;
    final fromEnvironment = await _env.resolve(providerId);
    if (fromEnvironment != null) return fromEnvironment;
    return keyOptional(providerId) ? kNoKeyPlaceholder : '';
  }

  /// Whether [providerId] works without a key.
  static bool keyOptional(String providerId) => providerId == kCustomEndpointId;

  /// The env-var key alone, ignoring the keychain. Lets the settings
  /// dialog tell the user "nothing pasted, but $GEMINI_API_KEY is
  /// covering you" instead of showing an empty field that looks broken.
  static String? fromEnv(String providerId) {
    final name = envVarNameFor(providerId);
    if (name == null) return null;
    final value = ShellEnv.instance.value(name);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The env var [providerId] would read, for UI copy. Null for a
  /// provider with no convention (a third-party broker plugin).
  static String? envVarNameFor(String providerId) => _env.envVarNames[providerId];

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
    if (trimmed.isNotEmpty) return trimmed;
    return fromEnv(providerId) ?? (keyOptional(providerId) ? kNoKeyPlaceholder : '');
  }
}
