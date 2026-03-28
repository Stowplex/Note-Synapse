import 'task_result_storage.dart';

/// Status of a context node in the hierarchical execution tree.
enum ContextNodeStatus { pending, active, completed, failed, paused }

/// Represents a skill loaded into an agent session.
///
/// Skills are session-scoped, pinned (never compacted), and deduplicated by noteId.
class LoadedSkill {
  final String noteId;
  final String content;
  const LoadedSkill({required this.noteId, required this.content});
}

/// Represents a node in the hierarchical context tree.
///
/// Each node represents a task/subtask with its own isolated execution context.
/// Child nodes can be spawned for complex tasks that benefit from context isolation.
/// When a child completes, it returns a condensed summary to its parent.
class ContextNode {
  final String id;
  final String? parentId;

  /// The objective/goal this context node is trying to accomplish.
  final String objective;

  /// Fine-grained execution trace (OTA cycles, tool calls, observations).
  /// This is the detailed log similar to GCC's log.md.
  final List<String> executionLog;

  /// Child context nodes for subtasks.
  final List<ContextNode> children;

  /// Condensed summary of this node's work for parent consumption.
  /// Generated when the node completes, similar to GCC's commit.md summary.
  String? summary;

  /// Current status of this context node.
  ContextNodeStatus status;

  /// Nesting depth in the tree (0 = root).
  final int depth;

  /// Maximum token budget for this context scope.
  final int maxContextTokens;

  /// Estimated current token usage in this context.
  int estimatedTokens;

  /// Timestamp when this context was created.
  final DateTime createdAt;

  /// Timestamp when this context was last updated.
  DateTime? updatedAt;

  /// Tools available within this context scope.
  final List<String> allowedTools;

  /// Structured result with TOC for lazy loading of task results.
  /// Set when task completes, enables on-demand section retrieval.
  TaskResultStorage? structuredResult;

  /// The most recent error encountered during execution in this context.
  /// Displayed in `LastRoundError` section to inform the agent of failures.
  String? lastError;

  /// Skills pinned to this session (root node only). Session-scoped, never compacted.
  /// Deduplicated by noteId. Not serialized to JSON (runtime state only).
  List<LoadedSkill> loadedSkills = [];

  ContextNode({
    required this.id,
    this.parentId,
    required this.objective,
    List<String>? executionLog,
    List<ContextNode>? children,
    this.summary,
    this.status = ContextNodeStatus.pending,
    this.depth = 0,
    this.maxContextTokens = 100000,
    this.estimatedTokens = 0,
    DateTime? createdAt,
    this.updatedAt,
    List<String>? allowedTools,
    this.lastError,
  }) : executionLog = executionLog ?? [],
       children = children ?? [],
       createdAt = createdAt ?? DateTime.now(),
       allowedTools = allowedTools ?? [];

  /// Adds an entry to the execution log and updates the timestamp.
  void log(String entry) {
    executionLog.add(entry);
    updatedAt = DateTime.now();
    // Rough token estimate: ~4 chars per token
    estimatedTokens = executionLog.join().length ~/ 4;
  }

  /// Adds a child context node for subtask delegation.
  void addChild(ContextNode child) {
    children.add(child);
    updatedAt = DateTime.now();
  }

  /// Finds a child context by ID.
  ContextNode? findChild(String childId) {
    for (final child in children) {
      if (child.id == childId) return child;
      final found = child.findChild(childId);
      if (found != null) return found;
    }
    return null;
  }

  /// Gets all completed children summaries for context building.
  List<String> getCompletedChildSummaries() {
    return children
        .where(
          (c) => c.status == ContextNodeStatus.completed && c.summary != null,
        )
        .map((c) => '## ${c.objective}\n${c.summary}')
        .toList();
  }

  /// Checks if context is approaching token limit.
  bool isNearTokenLimit({double threshold = 0.8}) {
    return estimatedTokens >= (maxContextTokens * threshold);
  }

  /// Creates a copy with updated fields.
  ContextNode copyWith({
    String? id,
    String? parentId,
    String? objective,
    List<String>? executionLog,
    List<ContextNode>? children,
    String? summary,
    ContextNodeStatus? status,
    int? depth,
    int? maxContextTokens,
    int? estimatedTokens,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? allowedTools,
  }) {
    return ContextNode(
      id: id ?? this.id,
      parentId: parentId ?? this.parentId,
      objective: objective ?? this.objective,
      executionLog: executionLog ?? List.from(this.executionLog),
      children: children ?? List.from(this.children),
      summary: summary ?? this.summary,
      status: status ?? this.status,
      depth: depth ?? this.depth,
      maxContextTokens: maxContextTokens ?? this.maxContextTokens,
      estimatedTokens: estimatedTokens ?? this.estimatedTokens,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,

      allowedTools: allowedTools ?? List.from(this.allowedTools),
      lastError: lastError ?? this.lastError,
    );
  }

  /// Serializes to JSON for potential snapshot/persistence.
  Map<String, dynamic> toJson() => {
    'id': id,
    'parentId': parentId,
    'objective': objective,
    'executionLog': executionLog,
    'children': children.map((c) => c.toJson()).toList(),
    'summary': summary,
    'status': status.name,
    'depth': depth,
    'maxContextTokens': maxContextTokens,
    'estimatedTokens': estimatedTokens,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'allowedTools': allowedTools,
    'lastError': lastError,
  };

  /// Deserializes from JSON for snapshot restoration.
  factory ContextNode.fromJson(Map<String, dynamic> json) {
    return ContextNode(
      id: json['id'] as String,
      parentId: json['parentId'] as String?,
      objective: json['objective'] as String,
      executionLog: List<String>.from(json['executionLog'] as List),
      children: (json['children'] as List)
          .map((c) => ContextNode.fromJson(c as Map<String, dynamic>))
          .toList(),
      summary: json['summary'] as String?,
      status: ContextNodeStatus.values.byName(json['status'] as String),
      depth: json['depth'] as int,
      maxContextTokens: json['maxContextTokens'] as int,
      estimatedTokens: json['estimatedTokens'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
      allowedTools: List<String>.from(json['allowedTools'] as List),
      lastError: json['lastError'] as String?,
    );
  }

  @override
  String toString() =>
      'ContextNode(id: $id, objective: $objective, status: $status, depth: $depth, children: ${children.length})';
}
