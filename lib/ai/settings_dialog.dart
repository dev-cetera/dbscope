import 'package:flutter/material.dart';

import '../connection/secure_store.dart';
import 'ai_key_resolver.dart';
import 'provider.dart';
import 'settings_store.dart';

/// AI configuration dialog. Lets the user paste API keys for each
/// registered provider, picks the active provider + model, and toggles
/// the sample-rows opt-in used by the regex inferrer.
///
/// Availability is decided at save time: we call `listModels` per
/// provider with the supplied key. A non-empty list = the key works and
/// that provider can be selected as active. Re-saving re-checks.
class AiSettingsDialog extends StatefulWidget {
  const AiSettingsDialog({super.key});

  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  final Map<String, TextEditingController> _keyControllers = {};
  final Map<String, List<String>> _availableModels = {};
  final Map<String, String?> _providerError = {};
  bool _initialised = false;
  bool _saving = false;
  String? _activeProviderId;
  String? _activeModel;
  bool _allowSampleRows = false;

  @override
  void initState() {
    super.initState();
    for (final p in AiBrokerRegistry.instance.all) {
      _keyControllers[p.id] = TextEditingController();
    }
    _hydrate();
  }

  Future<void> _hydrate() async {
    final settings = await AiSettingsStore.instance.load();
    for (final p in AiBrokerRegistry.instance.all) {
      final stored = await SecureStore.instance.readAiKey(p.id);
      _keyControllers[p.id]!.text = stored ?? '';
      if (stored != null && stored.isNotEmpty) {
        // Pre-populate the model dropdown for whatever we know works —
        // skip the network call until the user clicks Verify so opening
        // the dialog isn't a multi-second wait.
        _availableModels[p.id] = const [];
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
    for (final c in _keyControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _verify(AiBroker provider) async {
    // An empty field isn't "no key" — it means "use the environment",
    // which is exactly what the app will do at call time, so Verify has
    // to test the same key the assistant would use.
    final key = AiKeyResolver.effectiveKey(
      provider.id,
      _keyControllers[provider.id]!.text,
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
      final models = await provider.listModels(key);
      if (!mounted) return;
      setState(() {
        _availableModels[provider.id] = models;
        if (models.isEmpty) {
          _providerError[provider.id] =
              'API key was rejected or no compatible models.';
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
      );
      await AiSettingsStore.instance.save(settings);
      if (!mounted) return;
      Navigator.of(context).pop(settings);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = AiBrokerRegistry.instance.all;
    return AlertDialog(
      title: const Text('AI settings'),
      content: SizedBox(
        width: 520,
        child: !_initialised
            ? const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final p in providers) _providerSection(p),
                    const Divider(height: 24),
                    const Text(
                      'Active',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String?>(
                      initialValue: _activeProviderId,
                      decoration: const InputDecoration(
                        labelText: 'Provider',
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('(none)'),
                        ),
                        for (final p in providers)
                          DropdownMenuItem(value: p.id, child: Text(p.label)),
                      ],
                      onChanged: (v) {
                        setState(() {
                          _activeProviderId = v;
                          _activeModel = null;
                        });
                        // Auto-verify so the model dropdown populates
                        // without the user knowing to click Verify.
                        if (v != null) {
                          final provider = AiBrokerRegistry.instance.lookup(
                            v,
                          );
                          final key = AiKeyResolver.effectiveKey(
                            v,
                            _keyControllers[v]?.text ?? '',
                          );
                          final alreadyFetched =
                              (_availableModels[v] ?? const []).isNotEmpty;
                          if (provider != null &&
                              key.isNotEmpty &&
                              !alreadyFetched) {
                            _verify(provider);
                          }
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (_) {
                        final fetched =
                            _availableModels[_activeProviderId] ??
                            const <String>[];
                        // If the user saved a model previously but hasn't
                        // clicked Verify this session, the fetched list is
                        // empty — surface the saved model as a single
                        // entry so the dropdown can show it. Otherwise
                        // DropdownButton throws on `initialValue` not being
                        // in `items`.
                        final ids = <String>{...fetched};
                        if (_activeModel != null && _activeModel!.isNotEmpty) {
                          ids.add(_activeModel!);
                        }
                        final all = ids.toList();
                        return DropdownButtonFormField<String?>(
                          initialValue: _activeModel,
                          decoration: const InputDecoration(
                            labelText: 'Model',
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('(auto)'),
                            ),
                            for (final m in all)
                              DropdownMenuItem(value: m, child: Text(m)),
                          ],
                          onChanged: _activeProviderId == null
                              ? null
                              : (v) => setState(() => _activeModel = v),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _allowSampleRows,
                      onChanged: (v) => setState(() => _allowSampleRows = v),
                      title: const Text('Send sample rows for inference'),
                      subtitle: const Text(
                        'Needed for AI regex column-guess. Sends a few '
                        'real row values to the active provider.',
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
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }

  Widget _providerSection(AiBroker provider) {
    return _ProviderSection(
      provider: provider,
      keyController: _keyControllers[provider.id]!,
      availableModels: _availableModels[provider.id],
      error: _providerError[provider.id],
      onVerify: () => _verify(provider),
    );
  }
}

class _ProviderSection extends StatefulWidget {
  final AiBroker provider;
  final TextEditingController keyController;
  final List<String>? availableModels;
  final String? error;
  final VoidCallback onVerify;
  const _ProviderSection({
    required this.provider,
    required this.keyController,
    required this.availableModels,
    required this.error,
    required this.onVerify,
  });

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
    final envKey = envVarName == null
        ? null
        : AiKeyResolver.fromEnv(provider.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            provider.label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
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
              const SizedBox(width: 8),
              TextButton(
                onPressed: widget.onVerify,
                child: const Text('Verify'),
              ),
            ],
          ),
          if (envVarName != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                envKey != null
                    ? 'Using \$$envVarName from your environment.'
                    : 'Leave empty to use \$$envVarName '
                          '(File ▸ Environment…).',
                style: TextStyle(
                  fontSize: 11,
                  color: envKey != null ? Colors.green : Colors.grey,
                ),
              ),
            ),
          if (availableModels != null && availableModels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${availableModels.length} model(s) available',
                style: const TextStyle(fontSize: 11, color: Colors.green),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                style: const TextStyle(fontSize: 11, color: Colors.red),
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
