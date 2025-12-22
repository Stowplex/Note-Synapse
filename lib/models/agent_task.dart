enum AgentTaskStatus { pending, inProgress, completed, failed }

class AgentTask {
  final String id;
  final String description;
  AgentTaskStatus status;
  String? result;
  String? toolName;
  String? userComment; // Feedback for this specific step

  AgentTask({
    required this.id,
    required this.description,
    this.status = AgentTaskStatus.pending,
    this.result,
    this.toolName,
    this.userComment,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'status': status.toString(),
    'result': result,
    'toolName': toolName,
    'userComment': userComment,
  };
}
