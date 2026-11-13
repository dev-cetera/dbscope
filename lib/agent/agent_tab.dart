import '../tabs/tab_model.dart';
import 'agent_session.dart';

/// A conversation with the AI agent about one connection. Transient: the
/// session holds an AI provider's state and the transcript, neither of
/// which survives a restart.
class AgentTab extends TabModel {
  AgentTab({super.id, required super.connectionId});

  /// Made on the first message, from the AI settings in force then.
  AgentSession? session;

  /// Why the last message failed, shown under the transcript. Null when it
  /// didn't.
  String? error;

  /// Whether a message is being worked on. Its [cancelToken] stops it.
  bool get isWorking => cancelToken != null;

  @override
  String get title => 'Agent';
}
