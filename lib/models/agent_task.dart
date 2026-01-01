enum AgentTaskStatus { pending, inProgress, completed, failed, paused }

class AgentTask {
  final String id;
  final String description;

  /// Reference to parent task for hierarchical execution.
  /// Null for root-level tasks.
  final String? parentTaskId;

  /// Nesting depth in the task tree (0 = root level).
  final int depth;

  /// ID of the associated ContextNode for context management.
  String? contextNodeId;

  AgentTaskStatus status;
  String? result;

  /// AI-generated condensed summary for parent task consumption.
  /// This is the distilled result that gets passed up the hierarchy.
  String? condensedSummary;

  List<String> toolNames;
  String? userComment;
  List<String> executionHistory;
  int maxTurns;
  List<String> allowedTools;

  AgentTask({
    required this.id,
    required this.description,
    this.parentTaskId,
    this.depth = 0,
    this.contextNodeId,
    this.status = AgentTaskStatus.pending,
    this.result,
    this.condensedSummary,
    List<String>? toolNames,
    this.userComment,
    List<String>? executionHistory,
    this.maxTurns = 20,
    List<String>? allowedTools,
  }) : toolNames = toolNames ?? [],
       executionHistory = executionHistory ?? [],
       allowedTools = allowedTools ?? [];

  /// Whether this is a root-level task (no parent).
  bool get isRootTask => parentTaskId == null;

  /// Whether this is a subtask (has a parent).
  bool get isSubtask => parentTaskId != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'parentTaskId': parentTaskId,
    'depth': depth,
    'contextNodeId': contextNodeId,
    'status': status.toString(),
    'result': result,
    'condensedSummary': condensedSummary,
    'toolNames': toolNames,
    'userComment': userComment,
    'executionHistory': executionHistory,
    'maxTurns': maxTurns,
    'allowedTools': allowedTools,
  };
}
