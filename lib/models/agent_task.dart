enum AgentTaskStatus { pending, inProgress, completed, failed, paused }

class AgentTask {
  final String id;
  final String description;
  AgentTaskStatus status;
  String? result;
  String? toolName;
  String? userComment;
  List<String> executionHistory;
  int maxTurns;

  AgentTask({
    required this.id,
    required this.description,
    this.status = AgentTaskStatus.pending,
    this.result,
    this.toolName,
    this.userComment,
    this.executionHistory = const [],
    this.maxTurns = 20,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'status': status.toString(),
    'result': result,
    'toolName': toolName,
    'userComment': userComment,
    'executionHistory': executionHistory,
    'maxTurns': maxTurns,
  };
}
