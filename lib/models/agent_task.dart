enum AgentTaskStatus { pending, inProgress, completed, failed, paused }

class AgentTask {
  final String id;
  final String description;
  AgentTaskStatus status;
  String? result;
  List<String> toolNames;
  String? userComment;
  List<String> executionHistory;
  int maxTurns;
  List<String> allowedTools;

  AgentTask({
    required this.id,
    required this.description,
    this.status = AgentTaskStatus.pending,
    this.result,
    List<String>? toolNames,
    this.userComment,
    List<String>? executionHistory,
    this.maxTurns = 20,
    List<String>? allowedTools,
  }) : toolNames = toolNames ?? [],
       executionHistory = executionHistory ?? [],
       allowedTools = allowedTools ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'status': status.toString(),
    'result': result,
    'toolNames': toolNames,
    'userComment': userComment,
    'executionHistory': executionHistory,
    'maxTurns': maxTurns,
    'allowedTools': allowedTools,
  };
}
