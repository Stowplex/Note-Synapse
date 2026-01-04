import '../models/context_node.dart';
import 'ai_service.dart';
import 'agentic_settings_service.dart';
import 'logger_service.dart';
import '../models/generation_context.dart';
import 'model_selector.dart';

/// Default token budgets for context management.
/// These are fallbacks; prefer model's configured maxInputTokens.
const int kDefaultContextBudget = 100000;
const int kSubtaskBudgetRatio = 60;
const int kMinSubtaskBudget = 5000;

/// Gets the effective context budget for agent execution.
/// Returns: min(configuredCompactionThreshold, model.maxInputTokens)
Future<int> getModelContextBudget() async {
  final config = ModelSelector.instance.currentModelConfig;
  final modelLimit = config?.maxInputTokens ?? kDefaultContextBudget;
  final compactionThreshold =
      await AgenticSettingsService.getCompactionThreshold();
  return compactionThreshold < modelLimit ? compactionThreshold : modelLimit;
}

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
  /// Uses model's configured maxInputTokens if not explicitly provided.
  Future<ContextNode> createRootContext({
    required String objective,
    List<String> allowedTools = const [],
    int? maxTokens,
  }) async {
    final budget = maxTokens ?? await getModelContextBudget();
    final root = ContextNode(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      objective: objective,
      depth: 0,
      maxContextTokens: budget,
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

  /// Generates a smart handoff summary of work done so far.
  /// Uses a "handoff to colleague" persona to preserve essential context.
  Future<String> _generateIntermediateSummary(ContextNode node) async {
    final prompt =
        '''
Imagine you are handing off your work to a colleague. They will pick up where you left WITHOUT any prior context.

Your task: "${node.objective}"

Execution Log:
${node.executionLog.join('\n')}

Create a COMPACT handoff document that preserves:
1. Key data and findings needed to continue work
2. Current work state (what's done, what's pending)
3. Important URLs, citations, and sources
4. Tool outputs that may be referenced again

Remove:
- Redundant or superseded information
- Verbose tool output that has been processed (keep conclusions)
- Internal deliberation that led to conclusions (keep the conclusions only)

Output structured, scannable context. Not prose:
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

  /// Accumulated structured findings from tasks with extractFindings=true.
  /// Compact storage to minimize token usage between tasks.
  final List<Map<String, dynamic>> _accumulatedFindings = [];

  /// Gets accumulated findings count.
  int get findingsCount => _accumulatedFindings.length;

  /// Adds structured findings to the accumulator.
  void addFindings(List<Map<String, dynamic>> findings) {
    _accumulatedFindings.addAll(findings);
    rootContext?.log(
      '📌 Added ${findings.length} findings (total: ${_accumulatedFindings.length})',
    );
  }

  /// Builds rich context for synthesis tasks (includes all accumulated findings).
  String buildSynthesisContext(ContextNode node) {
    final buffer = StringBuffer();
    buffer.writeln(buildContextForNode(node));

    if (_accumulatedFindings.isNotEmpty) {
      buffer.writeln(
        '\n## Accumulated Research Findings (${_accumulatedFindings.length} items)\n',
      );
      buffer.writeln(
        'Use these findings to support your synthesis. Each finding should be considered for inclusion.\n',
      );

      for (var i = 0; i < _accumulatedFindings.length; i++) {
        final f = _accumulatedFindings[i];
        final fact = (f['fact'] ?? '').toString();
        final source = (f['source'] ?? '').toString();
        final url = (f['url'] ?? '').toString();
        final details = f['details'];

        buffer.writeln('${i + 1}. **$fact**');
        if (source.isNotEmpty) {
          if (url.isNotEmpty) {
            buffer.writeln('   — Source: $source ($url)');
          } else {
            buffer.writeln('   — Source: $source');
          }
        }
        // Include bullet point details if present
        if (details != null && details is List && details.isNotEmpty) {
          for (final detail in details) {
            buffer.writeln('   • $detail');
          }
        }
        buffer.writeln();
      }
    }

    return buffer.toString();
  }

  /// Clears all context state.
  void clear() {
    _rootContext = null;
    _currentContext = null;
    _contextMap.clear();
    _accumulatedFindings.clear();
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
