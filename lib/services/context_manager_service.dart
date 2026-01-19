import '../models/context_node.dart';
import '../models/task_result_storage.dart';
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

/// Structured info about a dependency task for TOC-based rendering.
class DependencyInfo {
  final String taskId;
  final String name;
  final String content;
  final String toc;
  final bool isShort;

  DependencyInfo({
    required this.taskId,
    required this.name,
    required this.content,
    required this.toc,
    required this.isShort,
  });
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
  ///
  /// [tocThreshold] is the word count threshold for inlining results vs showing TOC.
  String buildContextForNode(ContextNode node, {int tocThreshold = 1000}) {
    final buffer = StringBuffer();

    // Add global roadmap (root objective)
    final root = _getRoot(node);
    buffer.writeln('<GlobalObjective>');
    buffer.writeln(root.objective);
    if (root.summary != null) {
      buffer.writeln('Progress: ${root.summary}');
    }
    buffer.writeln('</GlobalObjective>');
    buffer.writeln();

    // Add ancestor context (TOC-based for lazy loading)
    final ancestors = _getAncestors(node);
    if (ancestors.isNotEmpty) {
      buffer.writeln('<ParentContext>');
      for (final ancestor in ancestors) {
        buffer.writeln(
          '<AncestorTask taskId="${ancestor.id}" goal="${ancestor.objective}">',
        );
        final result = ancestor.structuredResult;
        if (result != null) {
          // Use structured result with TOC-based lazy loading
          if (result.isShortSync(threshold: tocThreshold)) {
            // Short results: include inline
            buffer.writeln('<Result type="full">');
            buffer.writeln(result.fullResult);
            buffer.writeln('</Result>');
          } else {
            // Long results: include TOC only, use read_task_result for details
            buffer.writeln(
              '<Result type="toc" hint="Use read_task_result tool to fetch sections">',
            );
            buffer.writeln(result.toc);
            buffer.writeln('</Result>');
          }
        } else if (ancestor.summary != null) {
          // Fallback: use summary if no structured result
          buffer.writeln('<Result type="summary">');
          buffer.writeln(ancestor.summary);
          buffer.writeln('</Result>');
        } else {
          // Fallback: include recent log entries if no summary yet
          final recentLog = ancestor.executionLog.length > 5
              ? ancestor.executionLog.sublist(ancestor.executionLog.length - 5)
              : ancestor.executionLog;
          buffer.writeln('<Result type="log-preview">');
          buffer.writeln(recentLog.join('\n'));
          buffer.writeln('</Result>');
        }
        buffer.writeln('</AncestorTask>');
      }
      buffer.writeln('</ParentContext>');
      buffer.writeln();
    }

    // Add completed sibling summaries (TOC-based to save tokens)
    final siblings = _getCompletedSiblings(node);
    if (siblings.isNotEmpty) {
      buffer.writeln(
        '<CompletedSiblings note="Do NOT duplicate their work. Use read_task_result to fetch details.">',
      );
      for (final sibling in siblings) {
        buffer.writeln(
          '<Sibling id="${sibling.id}" objective="${sibling.objective}">',
        );
        final sr = sibling.structuredResult;
        if (sr != null) {
          if (sr.isShortSync(threshold: tocThreshold)) {
            // Short results: brief summary inline
            buffer.writeln(
              '<Result type="summary">${sr.fullResult.length > 200 ? sr.fullResult.substring(0, 200) + "..." : sr.fullResult}</Result>',
            );
          } else {
            // Long results: TOC only
            buffer.writeln(
              '<Result type="toc" hint="Use read_task_result(${sibling.id}) for details">${sr.toc}</Result>',
            );
          }
        } else {
          // Fallback: no structured result, hint to use read_task_result
          buffer.writeln(
            '<Result type="toc" hint="Use read_task_result(${sibling.id}, mode=full) to read">No structured TOC available.</Result>',
          );
        }
        buffer.writeln('</Sibling>');
      }
      buffer.writeln('</CompletedSiblings>');
      buffer.writeln();
    }

    // Add current node's execution log (detailed)
    buffer.writeln('<CurrentTask objective="${node.objective}">');
    buffer.writeln('<ExecutionLog>');
    buffer.writeln(node.executionLog.join('\n'));
    buffer.writeln('</ExecutionLog>');
    buffer.writeln('</CurrentTask>');

    return buffer.toString();
  }

  /// Builds isolated context for dynamically spawned subtasks.
  ///
  /// Unlike [buildContextForNode], this method:
  /// - Does NOT include full global/parent objectives (already in tailored briefing)
  /// - Only includes the subtask's own objective and execution log
  /// - Includes completed sibling summaries to avoid duplication
  ///
  /// The subtask's execution log already contains a tailored briefing from
  /// [_compactContextForSubtask] that provides just the right amount of context.
  String buildContextForSubtask(ContextNode node) {
    final buffer = StringBuffer();

    // Add completed sibling work (to avoid duplicating their efforts)
    final siblings = _getCompletedSiblings(node);
    if (siblings.isNotEmpty) {
      buffer.writeln(
        '<CompletedSiblings note="Do NOT duplicate their work. Use read_task_result to fetch details.">',
      );
      for (final sibling in siblings) {
        buffer.writeln(
          '<Sibling id="${sibling.id}" objective="${sibling.objective}">',
        );
        final sr = sibling.structuredResult;
        if (sr != null) {
          if (sr.isShortSync()) {
            // Short results: include full
            buffer.writeln('<Result type="full">');
            buffer.writeln(sr.fullResult);
            buffer.writeln('</Result>');
          } else {
            // Long results: TOC only
            buffer.writeln(
              '<Result type="toc" hint="Use read_task_result(${sibling.id}) for details">',
            );
            buffer.writeln(sr.toc);
            buffer.writeln('</Result>');
          }
        } else {
          // Fallback: no structured result, hint to use read_task_result
          buffer.writeln(
            '<Result type="toc" hint="Use read_task_result(${sibling.id}, mode=full) to read">No structured TOC available.</Result>',
          );
        }
        buffer.writeln('</Sibling>');
      }
      buffer.writeln('</CompletedSiblings>');
      buffer.writeln();
    }

    // Add current subtask's objective and execution log
    // The execution log already contains the tailored briefing from parent
    buffer.writeln('<CurrentTask objective="${node.objective}">');
    buffer.writeln('<ExecutionLog>');
    buffer.writeln(node.executionLog.join('\n'));
    buffer.writeln('</ExecutionLog>');
    buffer.writeln('</CurrentTask>');

    return buffer.toString();
  }

  /// Builds focused context for planner-created research tasks.
  ///
  /// Unlike [buildContextForNode], this method:
  /// - Does NOT include the full global objective (task description is sufficient)
  /// - Does NOT include parent context (avoids redundant repetition)
  /// - Includes only dependency results (tasks this one depends on)
  /// - Includes completed sibling summaries for context
  /// - Includes the task's own execution log
  ///
  /// Dependencies use TOC-based rendering:
  /// - Short results: included inline
  /// - Long results: TOC only + DependencyHint to use read_task_result
  ///
  /// This is used for regular planner-created tasks that are NOT the final
  /// deliverable and NOT dynamically spawned subtasks.
  String buildContextForResearchTask(
    ContextNode node, {
    List<String> dependencyResults = const [],
    List<DependencyInfo> structuredDependencies = const [],
  }) {
    final buffer = StringBuffer();

    // Use structured dependencies if available (TOC-based rendering)
    if (structuredDependencies.isNotEmpty) {
      final tocDependencies = <DependencyInfo>[];

      buffer.writeln('<DependencyResults>');
      for (final dep in structuredDependencies) {
        buffer.writeln(
          '<Dependency taskId="${dep.taskId}" name="${dep.name}">',
        );
        if (dep.isShort) {
          // Short results: include inline
          buffer.writeln('<Result type="full">');
          buffer.writeln(dep.content);
          buffer.writeln('</Result>');
        } else {
          // Long results: include TOC only
          buffer.writeln('<Result type="toc">');
          buffer.writeln(dep.toc);
          buffer.writeln('</Result>');
          tocDependencies.add(dep);
        }
        buffer.writeln('</Dependency>');
      }
      buffer.writeln('</DependencyResults>');
      buffer.writeln();

      // Add DependencyHint for long results that need fetching
      if (tocDependencies.isNotEmpty) {
        buffer.writeln('<DependencyHint>');
        buffer.writeln(
          'The following dependencies have TOC-only results. Use read_task_result tool to fetch full content:',
        );
        for (final dep in tocDependencies) {
          buffer.writeln(
            '- "${dep.name}" (id: ${dep.taskId}): Use read_task_result with task_id="${dep.taskId}" mode="full" or mode="section"',
          );
        }
        buffer.writeln('</DependencyHint>');
        buffer.writeln();
      }
    }
    // Fallback: Use legacy string-based dependency results
    else if (dependencyResults.isNotEmpty) {
      buffer.writeln('<DependencyResults>');
      for (final result in dependencyResults) {
        buffer.writeln(result);
      }
      buffer.writeln('</DependencyResults>');
      buffer.writeln();
    }

    // Add completed sibling summaries (parallel tasks already done)
    final siblings = _getCompletedSiblings(node);
    if (siblings.isNotEmpty) {
      buffer.writeln(
        '<CompletedSiblings note="Do NOT duplicate their work. Use read_task_result to fetch details.">',
      );
      for (final sibling in siblings) {
        buffer.writeln(
          '<Sibling id="${sibling.id}" objective="${sibling.objective}">',
        );
        final sr = sibling.structuredResult;
        if (sr != null) {
          if (sr.isShortSync()) {
            // Short results: include full
            buffer.writeln('<Result type="full">');
            buffer.writeln(sr.fullResult);
            buffer.writeln('</Result>');
          } else {
            // Long results: TOC only
            buffer.writeln(
              '<Result type="toc" hint="Use read_task_result(${sibling.id}) for details">',
            );
            buffer.writeln(sr.toc);
            buffer.writeln('</Result>');
          }
        } else {
          // Fallback: no structured result, hint to use read_task_result
          buffer.writeln(
            '<Result type="toc" hint="Use read_task_result(${sibling.id}, mode=full) to read">No structured TOC available.</Result>',
          );
        }
        buffer.writeln('</Sibling>');
      }
      buffer.writeln('</CompletedSiblings>');
      buffer.writeln();
    }

    // Add current task's objective and execution log (detailed)
    buffer.writeln('<CurrentTask objective="${node.objective}">');
    buffer.writeln('<ExecutionLog>');
    buffer.writeln(node.executionLog.join('\n'));
    buffer.writeln('</ExecutionLog>');
    buffer.writeln('</CurrentTask>');

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

  /// Generates a context-aware output transformation when a node completes.
  ///
  /// Instead of always summarizing, this method considers:
  /// - The current task's nature (creative, research, analysis)
  /// - What consuming tasks need from this output
  ///
  /// [consumingTaskDescriptions] - Optional list of dependent task descriptions
  /// that will use this output. Helps determine appropriate transformation.
  Future<String> generateFinalSummary(
    ContextNode node, {
    List<String> consumingTaskDescriptions = const [],
  }) async {
    // Determine the transformation approach based on context
    final consumingTasksContext = consumingTaskDescriptions.isNotEmpty
        ? '''
## Consuming Tasks (these tasks depend on your output):
${consumingTaskDescriptions.map((d) => '- $d').join('\n')}

Consider what these tasks need when deciding how to format your output.
'''
        : '';

    final prompt =
        '''
## OUTPUT TRANSFORMATION

You have completed the task: "${node.objective}"

$consumingTasksContext
Execution Log:
${node.executionLog.join('\n')}

Child Task Results:
${node.getCompletedChildSummaries().join('\n\n')}

## TRANSFORMATION RULES

Based on the task type and consuming tasks, choose the appropriate output format:

### PRESERVE FULL OUTPUT when:
- Task is creative/generative (write, create, expand, design, compose)
- Consuming task needs to build upon or extend this work
- Output is structured content (outlines, stories, code, specifications)
- Information loss would harm downstream tasks

### COMPRESS/SUMMARIZE when:
- Task is research/investigation (search, find, look up)  
- Output contains verbose raw data that's been processed
- Consuming task only needs conclusions, not raw data
- Token limits are a concern

### TRANSFORM STRATEGICALLY when:
- Extract key findings while preserving essential structure
- Keep citations, sources, and references
- Maintain data that consuming tasks explicitly need

## YOUR TASK

Analyze the current task objective and consuming tasks (if any).
Produce an output that BEST SERVES the downstream workflow.

If this is creative/generative work, output the FULL content.
If this is research/analysis, output structured findings.
''';

    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(
        values: {'type': 'context_transform', 'nodeId': node.id},
      ),
    );

    node.summary = response.trim();
    node.status = ContextNodeStatus.completed;

    // Log completion to parent if exists
    if (node.parentId != null) {
      final parent = _contextMap[node.parentId];
      parent?.log('← Subtask completed: ${node.objective}');
      parent?.log('Output: ${node.summary}');
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
      buffer.writeln();
      buffer.writeln(
        '<AccumulatedFindings count="${_accumulatedFindings.length}" note="Use these findings to support your synthesis">',
      );

      for (var i = 0; i < _accumulatedFindings.length; i++) {
        final f = _accumulatedFindings[i];
        final finding = (f['finding'] ?? f['fact'] ?? '').toString();
        final source = (f['source'] ?? '').toString();
        final url = (f['url'] ?? '').toString();
        final artifacts = f['artifacts'] as List<dynamic>?;

        buffer.writeln('<Finding index="${i + 1}">');
        buffer.writeln(finding);
        if (source.isNotEmpty) {
          if (url.isNotEmpty) {
            buffer.writeln('Source: $source ($url)');
          } else {
            buffer.writeln('Source: $source');
          }
        }

        // Render Artifacts
        if (artifacts != null && artifacts.isNotEmpty) {
          for (final a in artifacts) {
            if (a is Map) {
              final type = a['type']?.toString() ?? 'text';
              final content = a['content']?.toString() ?? '';

              if (type == 'bulletpoint') {
                buffer.writeln('• $content');
              } else if (type == 'code') {
                buffer.writeln('```\n$content\n```');
              } else if (type == 'image') {
                buffer.writeln('Resource: $content');
              } else {
                buffer.writeln(content);
              }
            }
          }
        }
        buffer.writeln('</Finding>');
      }
      buffer.writeln('</AccumulatedFindings>');
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

  // ==========================================================================
  // TOC Generation for Lazy Loading
  // ==========================================================================

  /// Generates a TaskResultStorage with TOC from a task result.
  ///
  /// Extracts markdown headers to create navigable sections that can be
  /// retrieved on-demand via the read_task_result tool.
  TaskResultStorage generateTocFromResult(
    String taskId,
    String goal,
    String result,
  ) {
    final sections = <ResultSection>[];
    final headerPattern = RegExp(r'^(#{1,6})\s+(.+)$', multiLine: true);
    final breadcrumbStack = <String>[];

    int? lastEnd;
    for (final match in headerPattern.allMatches(result)) {
      // Close previous section
      if (sections.isNotEmpty && lastEnd == null) {
        sections.last = ResultSection(
          breadcrumb: sections.last.breadcrumb,
          title: sections.last.title,
          startOffset: sections.last.startOffset,
          endOffset: match.start,
        );
      }

      final level = match.group(1)!.length;
      final title = match.group(2)!.trim();

      // Build breadcrumb path
      while (breadcrumbStack.length >= level) {
        breadcrumbStack.removeLast();
      }
      breadcrumbStack.add('${'#' * level} $title');
      final breadcrumb = breadcrumbStack.join(' > ');

      sections.add(
        ResultSection(
          breadcrumb: breadcrumb,
          title: title,
          startOffset: match.start,
          endOffset: result.length, // Will be updated when next section found
        ),
      );
      lastEnd = null;
    }

    return TaskResultStorage(
      taskId: taskId,
      goal: goal,
      fullResult: result,
      sections: sections,
    );
  }
}
