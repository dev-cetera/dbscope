import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:key_flow/key_flow.dart';
import 'package:widgets/widgets.dart';

import 'agent_runner.dart';
import 'agent_session.dart';
import 'agent_tab.dart';

/// The agent tab: the transcript, then a field to ask in. The work happens
/// in [sendToAgent]; this file only lays it out.
class AgentTabView extends StatefulWidget {
  const AgentTabView({super.key, required this.tab});
  final AgentTab tab;

  @override
  State<AgentTabView> createState() => _AgentTabViewState();
}

class _AgentTabViewState extends State<AgentTabView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || widget.tab.isWorking) return;
    _input.clear();
    unawaited(
      sendToAgent(
        tab: widget.tab,
        text: text,
        keys: KeyFlow.of(context),
        onChange: _onChange,
      ),
    );
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final tab = widget.tab;
    final entries = tab.session?.transcript ?? const <AgentEntry>[];
    final error = tab.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelHeader(
          padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          titleIcon: Icons.smart_toy_outlined,
          title: 'Agent',
          subtitle: 'Reads the schema, runs read-only queries, and drives the app',
        ),
        const Divider(height: 1.0),
        Expanded(
          child: ColoredBox(
            color: palette.field,
            child: entries.isEmpty
                ? const _EmptyHint()
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12.0),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8.0),
                    itemBuilder: (context, index) => _EntryView(entry: entries[index]),
                  ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12.0, 8.0, 12.0, 0.0),
            child: SelectableText(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: FieldName(
                  'Ask about the data, or ask it to open something…',
                  child: TextField(
                    controller: _input,
                    autofocus: true,
                    enabled: !tab.isWorking,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Ask about the data, or ask it to open something…',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8.0),
              if (tab.isWorking)
                TextButton.icon(
                  onPressed: () => tab.cancelToken?.cancel(),
                  icon: const Icon(Icons.stop, size: 18.0),
                  label: const Text('Stop'),
                )
              else
                FilledButton(onPressed: _send, child: const Text('Send')),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Text(
          'Try "Which tables hold customer data?", "How many orders were '
          'placed last week?" or "Open the orders table".\n\nThe agent only '
          'reads. It sees row values only if you allow it in AI ▸ Settings….',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.mutedText),
        ),
      ),
    );
  }
}

/// One transcript line: the user's message, a tool the agent ran, or its
/// answer.
class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});
  final AgentEntry entry;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return switch (entry) {
      AgentUserEntry(:final text) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 6.0),
          decoration: BoxDecoration(
            color: palette.accentSoft,
            borderRadius: BorderRadius.circular(palette.cornerRadius),
          ),
          child: SelectableText(text, style: TextStyle(color: palette.text)),
        ),
      ),
      AgentToolEntry(:final name, :final arguments, :final result, :final isError) => _ToolEntryView(
        name: name,
        arguments: arguments,
        result: result,
        isError: isError,
      ),
      AgentReplyEntry(:final text) => SelectableText(text, style: TextStyle(color: palette.text)),
    };
  }
}

/// A tool call, folded to one line; unfolds to show its arguments and
/// result.
class _ToolEntryView extends StatelessWidget {
  const _ToolEntryView({
    required this.name,
    required this.arguments,
    required this.result,
    required this.isError,
  });
  final String name;
  final Map<String, Object?> arguments;
  final String result;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final mono = TextStyle(
      fontFamily: palette.monoFontFamily,
      fontSize: palette.smallFontSize,
      color: isError ? Theme.of(context).colorScheme.error : palette.mutedText,
    );
    final details = arguments.isEmpty ? result : '${const JsonEncoder.withIndent('  ').convert(arguments)}\n→ $result';
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: palette.field),
      child: ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 16.0, bottom: 4.0),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: Icon(isError ? Icons.error_outline : Icons.build_outlined, size: 16.0, color: mono.color),
        title: Text('${isError ? 'Failed: ' : ''}$name', style: mono),
        children: [SelectableText(details, style: mono)],
      ),
    );
  }
}
