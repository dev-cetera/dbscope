// The agent's conversation loop: send the user's message with the tools,
// run whatever tools the model calls, hand the results back, and repeat
// until the model answers in words. Pure Dart, no Flutter: the tools are
// plain callbacks, so the loop is tested with a scripted broker
// (test/agent_session_test.dart).

import '../ai/provider.dart';

/// One thing the agent can do. [definition] is what the model sees; [run]
/// gets the model's arguments and returns the text handed back to it.
/// A [run] that throws becomes an error result the model can read and
/// recover from, never a crash.
class AgentTool {
  const AgentTool({required this.definition, required this.run});

  final AiTool definition;
  final Future<String> Function(Map<String, Object?> arguments) run;

  String get name => definition.name;
}

/// One line of the transcript the agent tab shows.
sealed class AgentEntry {
  const AgentEntry();
}

/// What the user typed.
final class AgentUserEntry extends AgentEntry {
  const AgentUserEntry(this.text);
  final String text;
}

/// A tool the model ran, with what it got back.
final class AgentToolEntry extends AgentEntry {
  const AgentToolEntry({
    required this.name,
    required this.arguments,
    required this.result,
    required this.isError,
  });
  final String name;
  final Map<String, Object?> arguments;
  final String result;
  final bool isError;
}

/// The model's answer in words.
final class AgentReplyEntry extends AgentEntry {
  const AgentReplyEntry(this.text);
  final String text;
}

/// Most model turns one message may take: each turn that calls tools is
/// one. Stops a model that keeps calling tools from running up a bill.
const kAgentMaxTurns = 12;

/// Longest tool result handed back to the model, in characters. Longer
/// results are cut, with a note saying so.
const kAgentMaxResultLength = 12000;

/// A conversation with the agent: the history the model sees, the
/// transcript the user sees, and the loop between them. One per agent tab.
class AgentSession {
  AgentSession({
    required this.broker,
    required this.apiKey,
    required this.model,
    required this.system,
  });

  final ChatBroker broker;
  final String apiKey;
  final String model;
  final String system;

  final List<AiMessage> _history = [];
  final List<AgentEntry> _transcript = [];

  /// Everything said and done so far, oldest first.
  List<AgentEntry> get transcript => List.unmodifiable(_transcript);

  /// Sends [text] and runs the loop until the model answers in words.
  /// [tools] are the ones in force now (the app's commands change as the
  /// user moves around, so they are passed per message). [onEntry] hears
  /// each transcript line as it is added, for a live view.
  ///
  /// When [abortTrigger] completes, the request in flight is aborted and
  /// this throws [AiAbortedException]; what happened before stays in the
  /// transcript. Throws [AiBrokerException] when the provider fails, and
  /// [StateError] when the model is still calling tools after
  /// [kAgentMaxTurns] turns.
  Future<String> send(
    String text, {
    required List<AgentTool> tools,
    Future<void>? abortTrigger,
    void Function(AgentEntry entry)? onEntry,
  }) async {
    void record(AgentEntry entry) {
      _transcript.add(entry);
      onEntry?.call(entry);
    }

    final byName = {for (final tool in tools) tool.name: tool};
    _history.add(AiMessage.user(text));
    record(AgentUserEntry(text));
    for (var turn = 0; turn < kAgentMaxTurns; turn++) {
      final done = await broker.chatWithMeta(
        apiKey: apiKey,
        model: model,
        request: ChatRequest(
          system: system,
          messages: List.of(_history),
          tools: [for (final tool in tools) tool.definition],
        ),
        abortTrigger: abortTrigger,
      );
      if (done.toolCalls.isEmpty) {
        final reply = done.isRefusal && done.text.trim().isEmpty
            ? 'The model declined to answer.'
            : done.text.trim();
        _history.add(AiMessage.assistant(reply));
        record(AgentReplyEntry(reply));
        return reply;
      }
      _history.add(AiMessage.assistantToolCalls(done.toolCalls, content: done.text));
      for (final call in done.toolCalls) {
        final (result, isError) = await _runTool(byName[call.name], call);
        _history.add(
          AiMessage.toolResult(toolCallId: call.id, content: result, isError: isError),
        );
        record(
          AgentToolEntry(
            name: call.name,
            arguments: call.arguments,
            result: result,
            isError: isError,
          ),
        );
      }
    }
    throw StateError(
      'The agent was still working after $kAgentMaxTurns steps, so it was '
      'stopped. Ask for something smaller.',
    );
  }

  static Future<(String, bool)> _runTool(AgentTool? tool, AiToolCall call) async {
    if (tool == null) {
      return ('There is no tool named "${call.name}" right now.', true);
    }
    try {
      return (_cut(await tool.run(call.arguments)), false);
    } on AiAbortedException {
      rethrow;
    } catch (e) {
      return (_cut('Failed: $e'), true);
    }
  }

  static String _cut(String text) => text.length <= kAgentMaxResultLength
      ? text
      : '${text.substring(0, kAgentMaxResultLength)}\n… (cut at $kAgentMaxResultLength characters)';
}
