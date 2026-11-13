import 'dart:async';

import 'package:flutter/material.dart';
import 'package:widgets/widgets.dart';

import '../connection/secure_store.dart';
import 'ai_key_resolver.dart';
import 'custom_endpoint.dart';
import 'provider.dart';
import 'settings_store.dart';

/// AI configuration dialog. Lets the user paste API keys for each
/// registered provider, point at their own OpenAI-compatible endpoint
/// (a local Ollama or LM Studio), pick the active provider + model, and
/// toggle the sample-rows opt-in used by the regex inferrer and the agent.
///
/// Verify asks the provider whether the key works (where it can say), then
/// lists its models. A non-empty list = that provider can be selected as
/// active.
class AiSettingsDialog extends StatefulWidget {
  const AiSettingsDialog({super.key});

  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  final Map<String, TextEditingController> _keyControllers = {};
  final _customUrlController = TextEditingController();
  final Map<String, List<String>> _availableModels = {};
  final Map<String, String?> _providerError = {};
  var _initialised = false;
  var _saving = false;
  String? _activeProviderId;
  String? _activeModel;
  var _allowSampleRows = false;

  @override
  void initState() {
    super.initState();
    unawaited(_hydrate());
  }

  /// One key field per provider, made the first time a provider shows up
  /// (the custom endpoint appears while the dialog is open).
  TextEditingController _keyControllerFor(String providerId) =>
      _keyControllers.putIfAbsent(providerId, TextEditingController.new);

  Future<void> _hydrate() async {
    // Loading also registers the saved custom endpoint, so it is listed.
    final settings = await AiSettingsStore.instance.load();
    _customUrlController.text = settings.customBaseUrl ?? '';
    for (final provider in AiBrokerRegistry.instance.all) {
      final stored = await SecureStore.instance.readAiKey(provider.id);
      _keyControllerFor(provider.id).text = stored ?? '';
      if (stored != null && stored.isNotEmpty) {
        // Pre-populate the model dropdown for whatever we know works —
        // skip the network call until the user clicks Verify so opening
        // the dialog isn't a multi-second wait.
        _availableModels[provider.id] = const [];
      }
    }
    if (!mounted) return;
    setState(() {
      _activeProviderId = settings.providerId;
      _activeModel = settings.model;
      _allowSampleRows = settings.allowSampleRows;
      _initialised = true;
    });
  }

  @override
  void dispose() {
    for (final controller in _keyControllers.values) {
      controller.dispose();
    }
    _customUrlController.dispose();
    super.dispose();
  }

  Future<void> _verify(AiBroker provider) async {
    // An empty field isn't "no key" — it means "use the environment",
    // which is exactly what the app will do at call time, so Verify has
    // to test the same key the assistant would use.
    final key = AiKeyResolver.effectiveKey(
      provider.id,
      _keyControllerFor(provider.id).text,
    );
    if (key.isEmpty) {
      final envVarName = AiKeyResolver.envVarNameFor(provider.id);
      setState(() {
        _availableModels[provider.id] = const [];
        _providerError[provider.id] = envVarName == null
            ? 'No API key set.'
            : 'No API key set, and \$$envVarName is not in your '
                  'environment.';
      });
      return;
    }
    setState(() {
      _providerError[provider.id] = null;
    });
    try {
      if (provider is KeyCheckBroker) {
        final check = await provider.checkKey(key);
        if (!check.isValid) {
          if (!mounted) return;
          setState(() {
            _availableModels[provider.id] = const [];
            _providerError[provider.id] = _describeKeyCheck(check);
          });
          return;
        }
      }
      final models = await provider.listModels(key);
      if (!mounted) return;
      setState(() {
        _availableModels[provider.id] = models;
        if (models.isEmpty) {
          _providerError[provider.id] = 'API key was rejected or no compatible models.';
        } else if (_activeProviderId == provider.id && _activeModel == null) {
          // Sensible default the first time the user verifies this
          // provider: take the first returned model. The user can
          // override before saving.
          _activeModel = models.first;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _availableModels[provider.id] = const [];
        _providerError[provider.id] = e.toString();
      });
    }
  }

  static String _describeKeyCheck(AiKeyCheck check) => switch (check.status) {
    AiKeyStatus.invalid => 'The provider rejected this API key.',
    AiKeyStatus.unreachable => 'Could not reach the provider: ${check.message ?? 'network error'}.',
    AiKeyStatus.error =>
      'The provider answered with an error: ${check.message ?? 'HTTP ${check.statusCode}'}.',
    AiKeyStatus.valid => 'The key works.',
  };

  /// The custom endpoint URL as typed, or null when the field is empty.
  String? get _customBaseUrl {
    final url = _customUrlController.text.trim();
    return url.isEmpty ? null : url;
  }

  /// Registers (or drops) the custom endpoint as typed, so its key field
  /// and Verify appear before Save.
  void _applyCustomEndpoint() {
    syncCustomEndpoint(AiSettings(customBaseUrl: _customBaseUrl));
    if (_customBaseUrl == null && _activeProviderId == kCustomEndpointId) {
      _activeProviderId = null;
      _activeModel = null;
    }
    setState(() {});
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // Persist or delete each key based on whether the user typed one.
      for (final entry in _keyControllers.entries) {
        final value = entry.value.text.trim();
        if (value.isEmpty) {
          await SecureStore.instance.deleteAiKey(entry.key);
        } else {
          await SecureStore.instance.writeAiKey(entry.key, value);
        }
      }
      final settings = AiSettings(
        providerId: _activeProviderId,
        model: _activeModel,
        allowSampleRows: _allowSampleRows,
        customBaseUrl: _customBaseUrl,
      );
      await AiSettingsStore.instance.save(settings);
      if (!mounted) return;
      Navigator.of(context).pop(settings);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Picks the active provider and clears the model.
  void _onProviderPicked(String? providerId) {
    setState(() {
      _activeProviderId = providerId;
      _activeModel = null;
    });
    // Auto-verify so the model dropdown populates
    // without the user knowing to click Verify.
    if (providerId != null) {
      final provider = AiBrokerRegistry.instance.lookup(
        providerId,
      );
      final key = AiKeyResolver.effectiveKey(
        providerId,
        _keyControllerFor(providerId).text,
      );
      final alreadyFetched = (_availableModels[providerId] ?? const []).isNotEmpty;
      if (provider != null && key.isNotEmpty && !alreadyFetched) {
        unawaited(_verify(provider));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = AiBrokerRegistry.instance.all;
    return AlertDialog(
      title: const Text('AI settings'),
      content: SizedBox(
        width: 520.0,
        child: !_initialised
            ? const SizedBox(
                height: 200.0,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final provider in providers) _providerSection(provider),
                    _CustomEndpointField(
                      controller: _customUrlController,
                      onApply: _applyCustomEndpoint,
                    ),
                    const Divider(height: 24.0),
                    const Text(
                      'Active',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8.0),
                    InstantDropdown(
                      decoration: const InputDecoration(
                        labelText: 'Provider',
                        isDense: true,
                      ),
                      isExpanded: true,
                      items: [
                        InstantDropdownItem(
                          label: '(none)',
                          selected: _activeProviderId == null,
                          onSelected: () => _onProviderPicked(null),
                        ),
                        for (final provider in providers)
                          InstantDropdownItem(
                            label: provider.label,
                            selected: provider.id == _activeProviderId,
                            onSelected: () => _onProviderPicked(provider.id),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8.0),
                    Builder(
                      builder: (_) {
                        final fetched = _availableModels[_activeProviderId] ?? const <String>[];
                        // If the user saved a model previously but hasn't
                        // clicked Verify this session, the fetched list is
                        // empty — surface the saved model as a single
                        // entry so the dropdown can show it as selected.
                        final ids = <String>{...fetched};
                        if (_activeModel != null && _activeModel!.isNotEmpty) {
                          ids.add(_activeModel!);
                        }
                        final all = ids.toList();
                        return InstantDropdown(
                          decoration: const InputDecoration(
                            labelText: 'Model',
                            isDense: true,
                          ),
                          isExpanded: true,
                          enabled: _activeProviderId != null,
                          items: [
                            InstantDropdownItem(
                              label: '(auto)',
                              selected: _activeModel == null,
                              onSelected: () => setState(() => _activeModel = null),
                            ),
                            for (final model in all)
                              InstantDropdownItem(
                                label: model,
                                selected: model == _activeModel,
                                onSelected: () => setState(() => _activeModel = model),
                              ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 16.0),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _allowSampleRows,
                      onChanged: (allow) => setState(() => _allowSampleRows = allow),
                      title: const Text('Send sample rows to the AI'),
                      subtitle: const Text(
                        'Needed for AI regex column-guess, and for the agent '
                        'to read query results. Sends real row values to the '
                        'active provider.',
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16.0,
                  height: 16.0,
                  child: CircularProgressIndicator(strokeWidth: 2.0),
                )
              : const Text('Save'),
        ),
      ],
    );
  }

  Widget _providerSection(AiBroker provider) {
    return _ProviderSection(
      provider: provider,
      keyController: _keyControllerFor(provider.id),
      availableModels: _availableModels[provider.id],
      error: _providerError[provider.id],
      onVerify: () => _verify(provider),
    );
  }
}

class _ProviderSection extends StatefulWidget {
  const _ProviderSection({
    required this.provider,
    required this.keyController,
    required this.availableModels,
    required this.error,
    required this.onVerify,
  });
  final AiBroker provider;
  final TextEditingController keyController;
  final List<String>? availableModels;
  final String? error;
  final VoidCallback onVerify;

  @override
  State<_ProviderSection> createState() => _ProviderSectionState();
}

class _ProviderSectionState extends State<_ProviderSection> {
  @override
  void initState() {
    super.initState();
    // The env-var fallback note appears and disappears as the field is
    // typed into, so the section has to rebuild on every keystroke.
    widget.keyController.addListener(_onKeyChanged);
  }

  @override
  void dispose() {
    widget.keyController.removeListener(_onKeyChanged);
    super.dispose();
  }

  void _onKeyChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    final availableModels = widget.availableModels;
    final error = widget.error;
    // Only meaningful while the field is empty — a pasted key wins over
    // the environment, so saying otherwise would be a lie.
    final envVarName = widget.keyController.text.trim().isEmpty
        ? AiKeyResolver.envVarNameFor(provider.id)
        : null;
    final envKey = envVarName == null ? null : AiKeyResolver.fromEnv(provider.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            provider.label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4.0),
          Row(
            children: [
              Expanded(
                child: FieldName(
                  '${provider.label} API key',
                  child: TextField(
                    controller: widget.keyController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API key',
                      isDense: true,
                      hintText: 'sk-... / AIza... / sk-ant-...',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8.0),
              TextButton(
                onPressed: widget.onVerify,
                child: const Text('Verify'),
              ),
            ],
          ),
          if (envVarName != null)
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Text(
                envKey != null
                    ? 'Using \$$envVarName from your environment.'
                    : 'Leave empty to use \$$envVarName '
                          '(File ▸ Environment…).',
                style: TextStyle(
                  fontSize: 11.0,
                  color: envKey != null ? Colors.green : Colors.grey,
                ),
              ),
            ),
          if (availableModels != null && availableModels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Text(
                '${availableModels.length} model(s) available',
                style: const TextStyle(fontSize: 11.0, color: Colors.green),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Text(
                error,
                style: const TextStyle(fontSize: 11.0, color: Colors.red),
              ),
            ),
        ],
      ),
    );
  }
}

/// The custom OpenAI-compatible endpoint's URL. Applying it (Enter or the
/// button) adds it to the provider list above, for its key and Verify.
class _CustomEndpointField extends StatelessWidget {
  const _CustomEndpointField({required this.controller, required this.onApply});
  final TextEditingController controller;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'OpenAI-compatible endpoint',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4.0),
          Row(
            children: [
              Expanded(
                child: FieldName(
                  'Base URL',
                  child: TextField(
                    controller: controller,
                    onSubmitted: (_) => onApply(),
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      isDense: true,
                      hintText: 'http://localhost:11434/v1',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8.0),
              TextButton(onPressed: onApply, child: const Text('Apply')),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4.0),
            child: Text(
              'A local model (Ollama, LM Studio) keeps your schema on this '
              'machine. Leave its key empty if the server needs none.',
              style: TextStyle(fontSize: 11.0, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

Future<AiSettings?> showAiSettingsDialog(BuildContext context) {
  return showDialog<AiSettings>(
    context: context,
    builder: (_) => const AiSettingsDialog(),
  );
}
