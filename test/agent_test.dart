// The AI agent's contract (lib/agent/):
// * AgentSession runs the tools the model calls, hands each result back
//   under its call id, and returns the model's first answer in words.
// * A tool that is missing or throws becomes an error result the model can
//   read; the loop carries on.
// * A model that keeps calling tools is stopped after kAgentMaxTurns turns.
// * db_run_query refuses SQL that can write without running anything, runs
//   the rest fenced in BEGIN TRANSACTION READ ONLY … COMMIT, and hands row
//   values to the model only when the user allowed it.
// * The app's commands that export secrets, change settings or the
//   connection are not offered to the agent; the agent-only open_table is.

import 'package:dbscope/agent/agent_session.dart';
import 'package:dbscope/agent/database_tools.dart';
import 'package:dbscope/ai/provider.dart';
import 'package:dbscope/db/executor.dart';
import 'package:dbscope/query/cancel_token.dart';
import 'package:dbscope/shell/app_commands.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:key_flow/key_flow.dart';

import 'support/fake_executor.dart';

/// Answers each chatWithMeta with the next scripted completion and records
/// the requests it was sent.
class _ScriptedBroker extends ChatBroker {
  _ScriptedBroker(this._replies);
  final List<AiCompletion> _replies;
  final List<ChatRequest> requests = [];

  @override
  String get id => 'scripted';
  @override
  String get label => 'Scripted';
  @override
  Future<List<String>> listModels(String apiKey) async => const ['m'];

  @override
  Future<AiCompletion> chatWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
    Future<void>? abortTrigger,
  }) async {
    requests.add(request);
    return _replies.removeAt(0);
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
    Future<void>? abortTrigger,
  }) => throw UnimplementedError();
}

AiCompletion _calls(List<AiToolCall> calls) => AiCompletion(text: '', toolCalls: calls);

AgentSession _session(ChatBroker broker) =>
    AgentSession(broker: broker, apiKey: 'k', model: 'm', system: 'sys');

AgentTool _tool(String name, Future<String> Function(Map<String, Object?>) run) => AgentTool(
  definition: AiTool(name: name, description: name, inputSchema: const {'type': 'object'}),
  run: run,
);

void main() {
  group('AgentSession', () {
    test('runs the called tool and returns the answer that follows', () async {
      final broker = _ScriptedBroker([
        _calls(const [
          AiToolCall(id: 'c1', name: 'count', arguments: {'table': 'orders'}),
        ]),
        const AiCompletion(text: ' 42 orders. '),
      ]);
      final seen = <Map<String, Object?>>[];
      final session = _session(broker);
      final reply = await session.send(
        'How many orders?',
        tools: [
          _tool('count', (arguments) async {
            seen.add(arguments);
            return '42';
          }),
        ],
      );
      expect(reply, '42 orders.');
      expect(seen, [
        {'table': 'orders'},
      ]);
      final result = broker.requests.last.messages.last;
      expect(result.toolCallId, 'c1');
      expect(result.content, '42');
      expect(result.isError, isFalse);
      expect(session.transcript.map((e) => e.runtimeType), [AgentUserEntry, AgentToolEntry, AgentReplyEntry]);
    });

    test('a missing or failing tool is reported to the model as an error', () async {
      final broker = _ScriptedBroker([
        _calls(const [
          AiToolCall(id: 'a', name: 'nope', arguments: {}),
          AiToolCall(id: 'b', name: 'boom', arguments: {}),
        ]),
        const AiCompletion(text: 'Sorry.'),
      ]);
      await _session(broker).send(
        'Go',
        tools: [_tool('boom', (_) async => throw StateError('broken'))],
      );
      final results = broker.requests.last.messages.where((m) => m.isToolResult).toList();
      expect(results.map((m) => m.isError), [true, true]);
      expect(results[0].content, contains('no tool named "nope"'));
      expect(results[1].content, contains('broken'));
    });

    test('stops a model that never stops calling tools', () async {
      final broker = _ScriptedBroker([
        for (var i = 0; i < kAgentMaxTurns; i++)
          _calls([AiToolCall(id: '$i', name: 'again', arguments: const {})]),
      ]);
      await expectLater(
        _session(broker).send('Loop', tools: [_tool('again', (_) async => 'ok')]),
        throwsStateError,
      );
      expect(broker.requests, hasLength(kAgentMaxTurns));
    });
  });

  group('db_run_query', () {
    Future<String> runQuery(FakeDbExecutor executor, String sql, {required bool sendRows}) {
      final tools = databaseTools(
        executor: executor,
        canQuery: true,
        sendRows: sendRows,
        cancelToken: CancelToken(),
        showQuery: (_, _) {},
      );
      return tools.firstWhere((tool) => tool.name == 'db_run_query').run({'sql': sql});
    }

    /// The probe (two statements) and BEGIN come back empty; the query gets
    /// one row.
    FakeDbExecutor executorWithOneRow() => FakeDbExecutor()
      ..enqueue(const DbResult(columns: [], rows: []))
      ..enqueue(const DbResult(columns: [], rows: []))
      ..enqueue(const DbResult(columns: [], rows: []))
      ..enqueueRow(['ada@example.com'], columns: ['email']);

    test('refuses SQL that can write, without running anything', () async {
      final executor = FakeDbExecutor();
      await expectLater(runQuery(executor, 'DELETE FROM users', sendRows: true), throwsA(anything));
      await expectLater(
        runQuery(executor, 'WITH d AS (DELETE FROM users RETURNING *) SELECT * FROM d', sendRows: true),
        throwsA(anything),
      );
      expect(executor.calls, isEmpty);
    });

    test('runs a read inside a read-only transaction', () async {
      final executor = executorWithOneRow();
      await runQuery(executor, 'SELECT email FROM users', sendRows: true);
      final statements = [for (final call in executor.calls) call.sql];
      expect(statements, containsAllInOrder(['BEGIN TRANSACTION READ ONLY', 'COMMIT']));
      expect(statements.indexOf('BEGIN TRANSACTION READ ONLY'), lessThan(statements.indexWhere((s) => s.contains('FROM users'))));
    });

    test('withholds row values unless the user allowed them', () async {
      final withheld = await runQuery(executorWithOneRow(), 'SELECT email FROM users', sendRows: false);
      expect(withheld, contains('Rows: 1'));
      expect(withheld, isNot(contains('ada@example.com')));

      final sent = await runQuery(executorWithOneRow(), 'SELECT email FROM users', sendRows: true);
      expect(sent, contains('ada@example.com'));
    });

    test('is not offered without the query capability', () {
      final names = [
        for (final tool in databaseTools(
          executor: FakeDbExecutor(),
          canQuery: false,
          sendRows: true,
          cancelToken: CancelToken(),
          showQuery: (_, _) {},
        ))
          tool.name,
      ];
      expect(names, isNot(contains('db_run_query')));
      expect(names, isNot(contains('db_show_query')));
      expect(names, contains('db_list_tables'));
    });
  });

  test('the app commands offered to the agent leave out the sensitive ones', () {
    final keys = KeyFlowController();
    addTearDown(keys.dispose);
    final tree = KeyTree.merge([KeyLayer(buildAppCommands(keys: keys))]);
    final agentIds = [
      for (final command in tree.toCommandList()) command['id'],
    ];
    for (final hidden in [
      'file.export_link',
      'file.import_link',
      'file.new_connection',
      'file.environment',
      'connection.export_link',
      'connection.read_only',
      'connection.disconnect',
      'ai.settings',
      'ai.agent',
    ]) {
      expect(agentIds, isNot(contains(hidden)), reason: hidden);
    }
    expect(agentIds, contains('view.open_table'));
    expect(agentIds, contains('file.new_query'));
  });
}
