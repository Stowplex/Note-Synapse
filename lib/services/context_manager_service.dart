import '../models/context_node.dart';
import 'ai_service.dart';
import 'logger_service.dart';
import '../models/generation_context.dart';

/// Default token budgets for context management.
const int kRootContextBudget = 100000;
const int kSubtaskBudgetRatio = 60;
const int kMinSubtaskBudget = 5000;

/// Service for managing hierarchical context in agent execution.
///
/// Handles context tree lifecycle, scoped context building, token budget
/// management, and automatic summarization when limits are approached.
class ContextManagerService {
  /// The root context node for the current execution session.
  ContextNode? _rootContext;

  /// Map of all context nodes by ID for quick lookup.
  final Map<String, ContextNode> _contextMap = {};

  /// The currently active context node.
  ContextNode? _currentContext;

  /// Gets the root context.
  ContextNode? get rootContext => _rootContext;

  /// Gets the current active context.
  ContextNode? get currentContext => _currentContext;

  /// Creates a new root context for an agent session.
  ContextNode createRootContext({
    required String objective,
    List<String> allowedTools = const [],
    int maxTokens = kRootContextBudget,
  }) {
    final root = ContextNode(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      objective: objective,
      depth: 0,
      maxContextTokens: maxTokens,
      status: ContextNodeStatus.active,
      allowedTools: allowedTools,
    );

    _rootContext = root;
    _currentContext = root;
    _contextMap[root.id] = root;

    root.log('=== Session Started ===');
    root.log('Objective: $objective');

    return root;
  }

  /// Creates a child context for subtask delegation.
  ContextNode createChildContext({
    required ContextNode parent,
    required String objective,
    List<String>? allowedTools,
  }) {
    final childBudget = _calculateChildBudget(parent);

    final child = ContextNode(
      id: '${parent.id}_${parent.children.length}',
      parentId: parent.id,
      objective: objective,
      depth: parent.depth + 1,
      maxContextTokens: childBudget,
      status: ContextNodeStatus.pending,
      allowedTools: allowedTools ?? List.from(parent.allowedTools),
    );

    parent.addChild(child);
    _contextMap[child.id] = child;

    parent.log('→ Spawned subtask: $objective');
    child.log('=== Subtask Started ===');
    child.log('Parent objective: ${parent.objective}');
    child.log('Subtask objective: $objective');

    return child;
  }

  /// Calculates token budget for a child context.
  int _calculateChildBudget(ContextNode parent) {
    final remaining = parent.maxContextTokens - parent.estimatedTokens;
    final calculated = (remaining * kSubtaskBudgetRatio) ~/ 100;
    return calculated > kMinSubtaskBudget ? calculated : kMinSubtaskBudget;
  }

  /// Sets the currently active context.
  void setActiveContext(ContextNode context) {
    _currentContext = context;
    context.status = ContextNodeStatus.active;
  }

  /// Builds the scoped context string for a specific node.
  ///
  /// Includes:
  /// - Global roadmap from root
  /// - Condensed summaries from ancestors
  /// - Completed sibling summaries (if relevant)
  /// - Current node's detailed execution log
  String buildContextForNode(ContextNode node) {
    final buffer = StringBuffer();

    // Add global roadmap (root objective)
    final root = _getRoot(node);
    buffer.writeln('## Global Objective');
    buffer.writeln(root.objective);
    if (root.summary != null) {
      buffer.writeln('Global Progress: ${root.summary}');
    }
    buffer.writeln();

    // Add ancestor context (condensed summaries only)
    final ancestors = _getAncestors(node);
    if (ancestors.isNotEmpty) {
      buffer.writeln('## Parent Context');
      for (final ancestor in ancestors) {
        buffer.writeln('### ${ancestor.objective}');
        if (ancestor.summary != null) {
          buffer.writeln(ancestor.summary);
        } else {
          // Include recent log entries if no summary yet
          final recentLog = ancestor.executionLog.length > 5
              ? ancestor.executionLog.sublist(ancestor.executionLog.length - 5)
              : ancestor.executionLog;
          buffer.writeln(recentLog.join('\n'));
        }
        buffer.writeln();
      }
    }

    // Add completed sibling summaries
    final siblings = _getCompletedSiblings(node);
    if (siblings.isNotEmpty) {
      buffer.writeln('## Related Completed Work');
      for (final sibling in siblings) {
        buffer.writeln('### ${sibling.objective}');
        buffer.writeln(sibling.summary ?? sibling.executionLog.join('\n'));
        buffer.writeln();
      }
    }

    // Add current node's execution log (detailed)
    buffer.writeln('## Current Task: ${node.objective}');
    buffer.writeln('### Execution Log');
    buffer.writeln(node.executionLog.join('\n'));

    return buffer.toString();
  }

  /// Gets the root node for any node in the tree.
  ContextNode _getRoot(ContextNode node) {
    if (node.parentId == null) return node;
    final parent = _contextMap[node.parentId];
    if (parent == null) return node;
    return _getRoot(parent);
  }

  /// Gets all ancestors of a node (from immediate parent to root).
  List<ContextNode> _getAncestors(ContextNode node) {
    final ancestors = <ContextNode>[];
    var current = node;
    while (current.parentId != null) {
      final parent = _contextMap[current.parentId];
      if (parent == null) break;
      ancestors.add(parent);
      current = parent;
    }
    return ancestors.reversed.toList(); // Root first
  }

  /// Gets completed siblings of a node.
  List<ContextNode> _getCompletedSiblings(ContextNode node) {
    if (node.parentId == null) return [];
    final parent = _contextMap[node.parentId];
    if (parent == null) return [];

    return parent.children
        .where(
          (c) => c.id != node.id && c.status == ContextNodeStatus.completed,
        )
        .toList();
  }

  /// Compacts a node's context when approaching token limit.
  ///
  /// Generates an intermediate summary and replaces detailed log with it.
  Future<void> compactNodeContext(ContextNode node) async {
    if (node.executionLog.length < 10) return; // Not worth compacting

    LoggerService.info('Compacting context for: ${node.objective}');

    try {
      final summary = await _generateIntermediateSummary(node);

      // Keep only the summary and last few entries
      final recentEntries = node.executionLog.length > 3
          ? node.executionLog.sublist(node.executionLog.length - 3)
          : <String>[];

      node.executionLog.clear();
      node.executionLog.add('[Previous work summarized]: $summary');
      node.executionLog.addAll(recentEntries);

      // Recalculate tokens
      node.estimatedTokens = node.executionLog.join().length ~/ 4;

      LoggerService.info(
        'Context compacted. New token estimate: ${node.estimatedTokens}',
      );
    } catch (e) {
      LoggerService.error('Failed to compact context: $e');
    }
  }

  /// Generates an intermediate summary of work done so far.
  Future<String> _generateIntermediateSummary(ContextNode node) async {
    final prompt =
        '''
Summarize the following execution log for the task: "${node.objective}"

Keep the summary:
- Concise but complete (preserve key facts, findings, and citations)
- Grounded in the actual results (no hallucination)
- Structured for easy reference

Execution Log:
${node.executionLog.join('\n')}

Provide a summary in 2-4 paragraphs:
''';

    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(
        values: {'type': 'context_summary', 'nodeId': node.id},
      ),
    );

    return response.trim();
  }

  /// Generates a final condensed summary when a node completes.
  Future<String> generateFinalSummary(ContextNode node) async {
    final prompt =
        '''
You have completed the task: "${node.objective}"

Generate a concise, well-grounded summary of the results for the parent task.

Requirements:
- Include all key findings, facts, and data points
- Preserve citations and sources
- Be concise but complete
- Structure for easy integration into broader context

Execution Log:
${node.executionLog.join('\n')}

Child Task Results:
${node.getCompletedChildSummaries().join('\n\n')}

Provide a summary (2-5 paragraphs):
''';

    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(
        values: {'type': 'final_summary', 'nodeId': node.id},
      ),
    );

    node.summary = response.trim();
    node.status = ContextNodeStatus.completed;

    // Log completion to parent if exists
    if (node.parentId != null) {
      final parent = _contextMap[node.parentId];
      parent?.log('← Subtask completed: ${node.objective}');
      parent?.log('Summary: ${node.summary}');
    }

    return node.summary!;
  }

  /// Marks a context as failed with an error message.
  void markContextFailed(ContextNode node, String error) {
    node.status = ContextNodeStatus.failed;
    node.log('ERROR: $error');
    node.summary = 'Task failed: $error';
  }

  /// Checks if a context should be compacted and does so if needed.
  Future<void> checkAndCompact(ContextNode node) async {
    if (node.isNearTokenLimit()) {
      await compactNodeContext(node);
    }
  }

  /// Clears all context state.
  void clear() {
    _rootContext = null;
    _currentContext = null;
    _contextMap.clear();
  }

  /// Gets a context node by ID.
  ContextNode? getContext(String id) => _contextMap[id];

  /// Exports the full context tree to JSON for snapshot/persistence.
  Map<String, dynamic>? exportSnapshot() {
    if (_rootContext == null) return null;
    return {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'rootContext': _rootContext!.toJson(),
    };
  }

  /// Imports a context tree from a snapshot.
  void importSnapshot(Map<String, dynamic> snapshot) {
    clear();

    final rootJson = snapshot['rootContext'] as Map<String, dynamic>;
    _rootContext = ContextNode.fromJson(rootJson);
    _indexContextTree(_rootContext!);
    _currentContext = _rootContext;
  }

  /// Recursively indexes all nodes in the tree.
  void _indexContextTree(ContextNode node) {
    _contextMap[node.id] = node;
    for (final child in node.children) {
      _indexContextTree(child);
    }
  }
}
