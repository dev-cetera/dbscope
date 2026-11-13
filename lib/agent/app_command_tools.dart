import 'package:key_flow/key_flow.dart';

import '../ai/provider.dart';
import 'agent_session.dart';

/// The app's own commands, as agent tools: the key_flow commands in force
/// where the focus is now, minus those hidden from agents (anything that
/// exports secrets, changes settings or writes). A command with input gets
/// the model's arguments; what it returns goes back to the model.
List<AgentTool> appCommandTools(KeyFlowController keys) => [
  for (final tool in keys.currentTree.toToolList())
    AgentTool(
      definition: AiTool(
        name: tool['name']! as String,
        description: tool['description']! as String,
        inputSchema: tool['parameters']! as Map<String, Object?>,
      ),
      run: (arguments) async {
        final result = await keys.runTool(tool['name']! as String, arguments);
        return result?.toString() ?? 'Done.';
      },
    ),
];
