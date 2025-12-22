enum AgentTaskStatus { pending, inProgress, completed, failed }

class AgentTask {
  final String id;
  final String description;
  AgentTaskStatus status;
  String? result;
  // potentially add sub-tasks or tool calls log?

  AgentTask({
    required this.id,
    required this.description,
    this.status = AgentTaskStatus.pending,
    this.result,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'status': status.toString(),
    'result': result,
  };
}
