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

  /// If true, this task's output should be passed directly to the user
  /// without summarization. Set by the LLM planner for synthesis/final tasks.
  final bool isFinalDeliverable;

  /// If true, LLM will extract key findings from this task's results
  /// to preserve for final synthesis. Set by planner for research/search tasks.
  final bool extractFindings;

  AgentTaskStatus status;
  String? result;

  /// AI-generated condensed summary for parent task consumption.
  /// This is the distilled result that gets passed up the hierarchy.
  String? condensedSummary;

  /// Compact structured findings extracted by LLM after task completion.
  /// Format: List of {fact, source, url?}
  List<Map<String, String>>? structuredFindings;

  List<String> toolNames;
  String? userComment;
  List<String> executionHistory;
  int maxTurns;
  List<String> allowedTools;

  /// User-attached notes to provide context for this specific task.
  /// These notes are included only in this task's context.
  List<String> contextNoteIds;

  AgentTask({
    required this.id,
    required this.description,
    this.parentTaskId,
    this.depth = 0,
    this.contextNodeId,
    this.isFinalDeliverable = false,
    this.extractFindings = false,
    this.status = AgentTaskStatus.pending,
    this.result,
    this.condensedSummary,
    this.structuredFindings,
    List<String>? toolNames,
    this.userComment,
    List<String>? executionHistory,
    this.maxTurns = 20,
    List<String>? allowedTools,
    List<String>? contextNoteIds,
  }) : toolNames = toolNames ?? [],
       executionHistory = executionHistory ?? [],
       allowedTools = allowedTools ?? [],
       contextNoteIds = contextNoteIds ?? [];

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
    'isFinalDeliverable': isFinalDeliverable,
    'extractFindings': extractFindings,
    'status': status.toString(),
    'result': result,
    'condensedSummary': condensedSummary,
    'structuredFindings': structuredFindings,
    'toolNames': toolNames,
    'userComment': userComment,
    'executionHistory': executionHistory,
    'maxTurns': maxTurns,
    'allowedTools': allowedTools,
    'contextNoteIds': contextNoteIds,
  };
}
