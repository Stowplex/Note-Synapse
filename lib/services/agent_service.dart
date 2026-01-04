import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../models/agent_task.dart';
import '../models/context_node.dart';
import '../models/generation_context.dart';
import '../models/mcp_endpoint.dart';
import 'tools/note_tools.dart';
import 'ai_service.dart';
import 'context_manager_service.dart';
import 'model_selector.dart';
import 'logger_service.dart';
import 'mcp_tool_integration_service.dart';
import 'mcp_service.dart';
import 'database_service.dart';

/// Callback for executing an external tool (MCP or local AI tool).
typedef ToolExecutor =
    Future<String> Function(
      String serviceName,
      String toolName,
      Map<String, dynamic> parameters,
      GenerationContext generationContext,
    );

/// Maximum allowed subtask depth (0=root, so 3 means 4 levels total)
const int kMaxSubtaskDepth = 3;

class AgentService extends ChangeNotifier {
  // State
  List<AgentTask> _tasks = [];
  Map<String, List<McpTool>> _externalTools = {};
  bool _isRunning = false;
  String? _currentThought;
  String? _finalAnswer;
  Map<String, dynamic>? _finalMetadata;
  ToolExecutor? _toolExecutor;

  // Hierarchical Context Management
  final ContextManagerService _contextManager = ContextManagerService();
  String? _currentObjective;

  /// User-attached notes to provide context for ALL tasks in the plan.
  List<String> _globalContextNoteIds = [];

  /// Gets the context manager for external access.
  ContextManagerService get contextManager => _contextManager;

  /// Gets the current objective.
  String? get currentObjective => _currentObjective;

  /// Gets the global context note IDs.
  List<String> get globalContextNoteIds =>
      List.unmodifiable(_globalContextNoteIds);

  /// Adds a note to the global context.
  void addGlobalContextNote(String noteId) {
    if (!_globalContextNoteIds.contains(noteId)) {
      _globalContextNoteIds.add(noteId);
      notifyListeners();
    }
  }

  /// Removes a note from the global context.
  void removeGlobalContextNote(String noteId) {
    if (_globalContextNoteIds.remove(noteId)) {
      notifyListeners();
    }
  }

  /// Clears all global context notes.
  void clearGlobalContextNotes() {
    _globalContextNoteIds.clear();
    notifyListeners();
  }

  /// Sets the global context notes (replacing existing).
  void setGlobalContextNotes(List<String> noteIds) {
    _globalContextNoteIds = List.from(noteIds);
    notifyListeners();
  }

  List<AgentTask> get tasks => List.unmodifiable(_tasks);
  Map<String, List<McpTool>> get externalTools =>
      Map.unmodifiable(_externalTools);
  bool get isRunning => _isRunning;
  String? get currentThought => _currentThought;
  String? get finalAnswer => _finalAnswer;
  Map<String, dynamic>? get finalMetadata => _finalMetadata;

  void clearState() {
    _tasks.clear();
    _finalAnswer = null;
    _finalMetadata = null;
    _currentThought = null;
    _isRunning = false;
    _toolExecutor = null;
    _currentObjective = null;
    _globalContextNoteIds.clear();
    _contextManager.clear();
    notifyListeners();
  }

  // ... (nativeTools and dbSchema definitions remain the same) ...

  /// ExecuteLoop with Hierarchical Context Management
  Future<void> _executeLoop() async {
    // Ensure root context exists (should be created in generatePlan)
    if (_contextManager.rootContext == null && _currentObjective != null) {
      _contextManager.createRootContext(
        objective: _currentObjective!,
        allowedTools: getAllToolNames(),
      );
    }

    final rootContext = _contextManager.rootContext;

    while (_isRunning &&
        _tasks.any(
          (t) =>
              t.status == AgentTaskStatus.pending ||
              t.status == AgentTaskStatus.paused,
        )) {
      final task = _tasks.firstWhere(
        (t) =>
            t.status == AgentTaskStatus.pending ||
            t.status == AgentTaskStatus.paused,
      );

      // Create or get context node for this task
      ContextNode taskContext;
      if (task.contextNodeId != null) {
        taskContext =
            _contextManager.getContext(task.contextNodeId!) ??
            _createTaskContext(task, rootContext);
      } else {
        taskContext = _createTaskContext(task, rootContext);
        task.contextNodeId = taskContext.id;
      }

      _contextManager.setActiveContext(taskContext);

      // Update status
      task.status = AgentTaskStatus.inProgress;
      taskContext.status = ContextNodeStatus.active;
      _currentThought = 'Working on: ${task.description}';
      notifyListeners();

      try {
        // Run ReAct loop for this task until it's done or paused
        while (task.status == AgentTaskStatus.inProgress && _isRunning) {
          // Check and compact context if nearing token limit
          await _contextManager.checkAndCompact(taskContext);

          // Build scoped context for this task
          // Final deliverable tasks get synthesis context with all accumulated findings
          final scopedContext = task.isFinalDeliverable
              ? _contextManager.buildSynthesisContext(taskContext)
              : _contextManager.buildContextForNode(taskContext);

          // Include attached notes context (global + task-specific)
          final attachedNotesContext = await _buildAttachedNotesContext(task);
          final fullContext = attachedNotesContext.isNotEmpty
              ? '$attachedNotesContext\n\n$scopedContext'
              : scopedContext;

          await _performTask(task, fullContext);

          // Small delay to prevent tight loops
          if (task.status == AgentTaskStatus.inProgress) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }

        if (task.status == AgentTaskStatus.paused) {
          taskContext.status = ContextNodeStatus.paused;
          _isRunning = false;
          _currentThought = 'Task paused: ${task.description}';
          notifyListeners();
          return;
        }

        // If we exited loop without being paused, task should be completed or failed.
        if (!_isRunning && task.status == AgentTaskStatus.inProgress) {
          return;
        }

        // Generate condensed summary for completed tasks
        if (task.status == AgentTaskStatus.completed) {
          // Extract structured findings if marked for extraction
          if (task.extractFindings && task.result != null) {
            try {
              task.structuredFindings = await _extractStructuredFindings(task);
              _contextManager.addFindings(task.structuredFindings ?? []);
              taskContext.log(
                'Extracted ${task.structuredFindings?.length ?? 0} findings',
              );
            } catch (e) {
              LoggerService.error('Failed to extract findings: $e');
            }
          }

          // Extract findings from dynamically spawned subtasks
          if (task.spawnedSubtaskIds.isNotEmpty) {
            for (final subtaskId in task.spawnedSubtaskIds) {
              final subtask = _tasks
                  .where((t) => t.id == subtaskId)
                  .firstOrNull;
              if (subtask != null &&
                  subtask.status == AgentTaskStatus.completed) {
                try {
                  // Extract structured findings from subtask's execution history
                  // (same mechanism as extractFindings=true tasks)
                  subtask.structuredFindings = await _extractStructuredFindings(
                    subtask,
                  );
                  _contextManager.addFindings(subtask.structuredFindings ?? []);

                  // Log findings summary to parent context
                  final findingsCount = subtask.structuredFindings?.length ?? 0;
                  taskContext.log(
                    'Subtask "${subtask.description}" completed with $findingsCount findings',
                  );
                } catch (e) {
                  LoggerService.error('Failed to extract subtask findings: $e');
                }
              }
            }
          }

          if (task.isFinalDeliverable) {
            // Preserve full result for final deliverable tasks - no summarization
            task.condensedSummary = task.result;
            taskContext.summary = task.result;
            taskContext.status = ContextNodeStatus.completed;
            taskContext.log('Final deliverable preserved (no summarization)');
          } else {
            try {
              task.condensedSummary = await _contextManager
                  .generateFinalSummary(taskContext);
              taskContext.log('Task completed with result: ${task.result}');
            } catch (e) {
              LoggerService.error('Failed to generate task summary: $e');
              task.condensedSummary = task.result;
              taskContext.status = ContextNodeStatus.completed;
            }
          }
        } else if (task.status == AgentTaskStatus.failed) {
          _contextManager.markContextFailed(
            taskContext,
            task.result ?? 'Unknown error',
          );
        }
      } catch (e) {
        task.status = AgentTaskStatus.failed;
        task.result = 'Error: $e';
        _contextManager.markContextFailed(taskContext, '$e');
      }
      notifyListeners();
    }

    // Generate final answer
    if (_tasks.every((t) => t.status == AgentTaskStatus.completed)) {
      _currentThought = 'Generating final response...';
      notifyListeners();

      try {
        // Check if we have a final deliverable task - use its result directly
        final deliverableTask = _tasks
            .where((t) => t.isFinalDeliverable)
            .lastOrNull;

        if (deliverableTask != null && deliverableTask.result != null) {
          // Use the deliverable's result directly - this IS the user's answer
          _finalAnswer = deliverableTask.result!;
          _finalMetadata = {
            'modelUsed': ModelSelector.instance.currentModelConfig?.id,
            'is_agent_summary': true,
            'objective': _currentObjective,
            'deliverable_task': deliverableTask.description,
          };
          _currentThought = 'All tasks completed.';
        } else {
          // Fallback: generate summary from context (no deliverable marked)
          final rootCtx = _contextManager.rootContext;
          final contextSummary = rootCtx != null
              ? _contextManager.buildContextForNode(rootCtx)
              : _buildLegacyContext();
          await _generateFinalSummary(contextSummary);
          _currentThought = 'All tasks completed.';
        }
      } catch (e) {
        _finalAnswer =
            "Execution finished, but failed to generate summary. See task details.";
        LoggerService.error('Failed to generate summary: $e');
      }
    }
  }

  /// Creates a context node for a task, linking it to parent context.
  ContextNode _createTaskContext(AgentTask task, ContextNode? rootContext) {
    if (rootContext == null) {
      return _contextManager.createRootContext(
        objective: task.description,
        allowedTools: task.allowedTools,
      );
    }

    // For subtasks, create child context
    if (task.isSubtask) {
      final parentTask = _tasks.firstWhere(
        (t) => t.id == task.parentTaskId,
        orElse: () => task,
      );
      final parentContext = parentTask.contextNodeId != null
          ? _contextManager.getContext(parentTask.contextNodeId!)
          : rootContext;

      return _contextManager.createChildContext(
        parent: parentContext ?? rootContext,
        objective: task.description,
        allowedTools: task.allowedTools.isNotEmpty ? task.allowedTools : null,
      );
    }

    // For root-level tasks in a multi-task plan, use root context directly
    // or create a child context for isolation
    return _contextManager.createChildContext(
      parent: rootContext,
      objective: task.description,
      allowedTools: task.allowedTools.isNotEmpty ? task.allowedTools : null,
    );
  }

  /// Builds legacy context from completed tasks (fallback for backwards compatibility).
  String _buildLegacyContext() {
    final buffer = StringBuffer();
    for (final t in _tasks) {
      if (t.status == AgentTaskStatus.completed) {
        buffer.writeln('Task: ${t.description}');
        buffer.writeln('Result: ${t.condensedSummary ?? t.result}');
        buffer.writeln('---');
      }
    }
    return buffer.toString();
  }

  /// Builds context string from attached notes (global + task-specific).
  Future<String> _buildAttachedNotesContext(AgentTask task) async {
    final allNoteIds = <String>{
      ..._globalContextNoteIds,
      ...task.contextNoteIds,
    };

    if (allNoteIds.isEmpty) {
      return '';
    }

    final db = DatabaseService();
    final buffer = StringBuffer();
    buffer.writeln('## User-Provided Context Notes');
    buffer.writeln();

    for (final noteId in allNoteIds) {
      try {
        final note = await db.getNoteById(noteId);
        if (note != null) {
          final isGlobal = _globalContextNoteIds.contains(noteId);
          final scope = isGlobal ? '(Global)' : '(Task-specific)';
          buffer.writeln('### ${note.title} $scope');
          if (note.tags.isNotEmpty) {
            buffer.writeln('Tags: ${note.tags.join(", ")}');
          }
          buffer.writeln();
          buffer.writeln(note.content);
          buffer.writeln();
          buffer.writeln('---');
          buffer.writeln();
        }
      } catch (e) {
        LoggerService.error('Failed to load context note $noteId: $e');
      }
    }

    return buffer.toString();
  }

  Future<void> _generateFinalSummary(String globalContext) async {
    // Include the original objective to ensure the response addresses user's intent
    final objective = _currentObjective ?? 'the user\'s request';

    final prompt =
        '''
USER'S ORIGINAL OBJECTIVE:
"$objective"

EXECUTION CONTEXT (results from all tasks):
$globalContext

INSTRUCTIONS:
You have completed a series of tasks to achieve the user's objective stated above.
Now provide the FINAL RESPONSE to the user that directly addresses their original request.

This is NOT a summary of what you did - this IS the deliverable the user asked for.
- If they asked for a list, provide the list
- If they asked for analysis, provide the analysis
- If they asked for writing, provide the writing
- If they asked for information, provide that information

Format your response with Markdown for readability.

When referring to notes or conversations, use inline markdown links with the synapseresource:// URI scheme:
- For notes: [Note Title](synapseresource://note/<note_id>)
- For conversations: [Conversation Title](synapseresource://conversation/<conversation_id>)

Respond directly to: "$objective"
''';

    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(values: {'type': 'agent_summary'}),
    );

    _finalAnswer = response;
    // Capture metadata for the UI
    _finalMetadata = {
      'modelUsed': ModelSelector.instance.currentModelConfig?.id,
      'is_agent_summary': true,
      'objective': _currentObjective,
    };
    notifyListeners();
  }

  /// Extracts structured key findings from a task's RAW OBSERVATIONS.
  /// Uses executionHistory (raw tool output) instead of task.result (LLM summary)
  /// to prevent information loss from double-compression.
  /// Called when task.extractFindings is true.
  Future<List<Map<String, String>>> _extractStructuredFindings(
    AgentTask task,
  ) async {
    // Extract raw observations from execution history to preserve URLs and details
    final rawObservations = _getRawObservations(task);

    // If no observations, fall back to task.result
    final sourceContent = rawObservations.isNotEmpty
        ? rawObservations.join('\n\n---\n\n')
        : task.result ?? '';

    if (sourceContent.isEmpty) {
      return [];
    }

    final prompt =
        '''
Extract key findings from this research task for final synthesis.

Task: ${task.description}

RAW TOOL OBSERVATIONS (preserve URLs and specific data):
$sourceContent

## EXTRACTION RULES

1. Extract ONLY verifiable facts with clear sources
2. Each finding MUST have:
   - fact: A specific data point, statistic, or claim (1-2 sentences)
   - source: The organization or publication name (e.g., "CDC", "USDA", "NSF 2024")
   - url: The actual URL if mentioned in the observations, otherwise use empty string ""

3. CRITICAL: URLs are present in the observations - extract them accurately
4. Do NOT use placeholders like "Not specified" or "Unspecified" for URLs
5. If no URL is available, use empty string: "url": ""
6. Maximum 10 findings per task

## OUTPUT FORMAT

Return ONLY valid JSON array:
[
  {"fact": "Specific finding with numbers", "source": "Organization Name", "url": "https://..."},
  {"fact": "Another finding", "source": "Report Name 2024", "url": ""}
]

If no findings worth preserving, return: []
''';

    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(
        values: {'type': 'extract_findings', 'taskId': task.id},
      ),
    );

    return _parseFindings(response);
  }

  /// Extracts raw observation content from task execution history.
  /// Returns list of observation strings (tool outputs) before LLM summarization.
  List<String> _getRawObservations(AgentTask task) {
    final observations = <String>[];
    for (final entry in task.executionHistory) {
      if (entry.startsWith('Observation:')) {
        observations.add(entry.substring('Observation:'.length).trim());
      }
    }
    return observations;
  }

  /// Parses findings JSON from LLM response.
  /// Normalizes URL values to remove placeholders like "Not specified".
  List<Map<String, String>> _parseFindings(String response) {
    try {
      String cleanResponse = response.trim();
      if (cleanResponse.startsWith('```json')) {
        cleanResponse = cleanResponse.replaceFirst('```json', '');
      }
      if (cleanResponse.startsWith('```')) {
        cleanResponse = cleanResponse.replaceFirst('```', '');
      }
      cleanResponse = cleanResponse.replaceAll(RegExp(r'```$'), '').trim();

      final List<dynamic> jsonList = jsonDecode(cleanResponse);
      return jsonList.map((item) {
        final map = item as Map<String, dynamic>;

        // Normalize URL: remove placeholders, keep only actual URLs
        String url = (map['url'] ?? '').toString().trim();
        if (_isPlaceholderUrl(url)) {
          url = '';
        }

        return <String, String>{
          'fact': (map['fact'] ?? '').toString().trim(),
          'source': (map['source'] ?? '').toString().trim(),
          'url': url,
        };
      }).toList();
    } catch (e) {
      LoggerService.error('Failed to parse findings: $e');
      return [];
    }
  }

  /// Checks if a URL string is a placeholder rather than an actual URL.
  bool _isPlaceholderUrl(String url) {
    if (url.isEmpty) return true;
    final lower = url.toLowerCase();
    return lower.contains('not specified') ||
        lower.contains('not provided') ||
        lower.contains('unspecified') ||
        lower.contains('unavailable') ||
        lower.contains('n/a') ||
        lower == 'none' ||
        lower == 'null' ||
        (!url.startsWith('http://') && !url.startsWith('https://'));
  }

  // Tools
  final List<NativeTool> _nativeTools = [
    NoteSearchTool(),
    NoteReadTool(),
    RunSqlTool(),
    ListFiltersTool(),
    ModifyNoteTool(),
  ];
  List<NativeTool> get nativeTools => List.unmodifiable(_nativeTools);

  Map<String, String> getToolToServiceMap() {
    final map = <String, String>{};
    for (final t in _nativeTools) {
      map[t.name] = 'System';
    }
    for (final entry in _externalTools.entries) {
      for (final t in entry.value) {
        map[t.name] = entry.key;
      }
    }
    return map;
  }

  List<String> getAllToolNames() {
    final names = _nativeTools.map((t) => t.name).toList();
    for (final list in _externalTools.values) {
      names.addAll(list.map((t) => t.name));
    }
    return names;
  }

  // DB Schema is now fetched dynamically from DatabaseService

  /// Generates an initial plan based on the objective.
  /// Updates internal state and returns the tasks.
  Future<List<AgentTask>> generatePlan(
    String objective, {
    Map<String, List<McpTool>> activeTools = const {},
    ToolExecutor? executeTool,
    String? context,
    List<PlatformFile> contextAttachments = const [],
  }) async {
    _externalTools = activeTools;
    _toolExecutor = executeTool;
    _currentThought = 'Generating plan...';
    // Reset previous results
    _finalAnswer = null;
    _finalMetadata = null;

    // Store objective and initialize root context for hierarchical management
    _currentObjective = objective;
    _contextManager.clear();
    _contextManager.createRootContext(
      objective: objective,
      allowedTools: getAllToolNames(),
    );
    _contextManager.rootContext?.log('Planning phase started');
    if (context != null) {
      _contextManager.rootContext?.log('Additional context provided: $context');
    }

    notifyListeners();

    // Build descriptions for external tools if available
    // Build descriptions for external tools
    String externalToolsDesc = '';
    if (_externalTools.isNotEmpty) {
      externalToolsDesc = '\nExternal Tools:\n';
      for (final entry in _externalTools.entries) {
        externalToolsDesc += 'Service: ${entry.key}\n';
        for (final tool in entry.value) {
          externalToolsDesc +=
              '- ${tool.name}: ${tool.description}\n  Args: ${tool.inputSchema}\n';
        }
      }
    }

    final nativeToolsDesc = _nativeTools
        .map(
          (t) =>
              '- ${t.name}: ${t.description}\n  Args: ${t.inputSchema['properties']}',
        )
        .join('\n');

    final contextSection = context != null
        ? "\nAdditional Context:\n$context\n"
        : "";

    // Get table schema dynamically
    final dbSchema = DatabaseService.getSchemaDescription();

    final prompt =
        '''
You are an intelligent agent that plans and executes tasks to solve an objective.

Objective: "$objective"
$contextSection
Available Tools:
$nativeToolsDesc
$externalToolsDesc

Database Schema (for run_sql):
$dbSchema

## EXECUTION STRATEGY GUIDANCE

Choose an appropriate strategy based on the objective and available tools:

**Quick Lookup** (1-2 tasks):
- Simple factual questions with direct answers
- Single tool call sufficient
- Example: "What tags do I have?" → use `ls` or `run_sql`

**Iterative Research** (3-6+ tasks):
- Complex questions requiring multiple sources
- When you have search tools (web search, database search)
- Plan: broad search → analyze gaps → targeted searches → synthesize
- Mark intermediate search tasks with "extractFindings": true
- Example: "What are the latest developments in X?"

**Multi-Step Workflow** (variable):
- Tasks with dependencies (read → modify → verify)
- Each step builds on previous results
- Example: "Find notes about X and summarize them"

## NOTE EXPLORATION (when working with user's notes)

DON'T read full note content immediately!

Tool Priority for Note Discovery:
1. `ls` / `run_sql` → metadata exploration (no content loading) - PREFERRED
2. `search_notes` → keyword-based filtering
3. `read_note` mode='toc'/'summary' → structural overview
4. `read_note` mode='full' → only for targeted deep reads

Example: "identify knowledge gaps in transformer notes":
1. `run_sql` → SELECT id, title, tags FROM notes WHERE tags LIKE '%transformer%'
2. `ls` → find relevant filters
3. `read_note` mode='toc' → scan structure of key notes
4. `read_note` full only for specific sections needed

## TASK CONFIGURATION

For each task, you can specify:
- "tools": List of tools to use
- "isFinalDeliverable": true for the task producing user's final answer (only one task)
- "extractFindings": true if this task's detailed results should be preserved for synthesis (use for research/search tasks)

## OUTPUT FORMAT

Return ONLY valid JSON:
[
  {
    "description": "Step description",
    "tools": ["tool_name"],
    "isFinalDeliverable": false,
    "extractFindings": true
  }
]

Example:
[
  {"description": "Explore note structure with SQL", "tools": ["run_sql"], "extractFindings": true},
  {"description": "Search for relevant notes", "tools": ["search_notes"], "extractFindings": true},
  {"description": "Synthesize comprehensive report", "tools": [], "isFinalDeliverable": true}
]

If no tools are needed for a step (e.g. analysis), use: "tools": [].
Only use the tools listed above.
''';

    try {
      final response = await AIService.generateWithAttachments(
        prompt,
        contextAttachments,
        generationContext: GenerationContext(values: {'type': 'agent_plan'}),
      );

      final List<AgentTask> tasks = _parseTasksFromJson(
        response,
        activeTools: getAllToolNames(),
      );
      _tasks = tasks;

      _currentThought = 'Plan generated. Waiting for review.';
      notifyListeners();
      return _tasks;
    } catch (e) {
      LoggerService.error('Failed to generate plan: $e');
      // Fallback
      _tasks = [
        AgentTask(
          id: const Uuid().v4(),
          description: objective,
          status: AgentTaskStatus.pending,
        ),
      ];
      notifyListeners();
      return _tasks;
    }
  }

  /// Revises the current plan based on user feedback.
  Future<List<AgentTask>> revisePlan(String feedback) async {
    _currentThought = 'Revising plan...';
    notifyListeners();

    final currentPlanJson = jsonEncode(
      _tasks
          .map(
            (t) => {
              'description': t.description,
              'tools': t.toolNames,
              if (t.userComment != null && t.userComment!.isNotEmpty)
                'feedback': t.userComment,
            },
          )
          .toList(),
    );

    // Get table schema dynamically
    final dbSchema = DatabaseService.getSchemaDescription();

    final prompt =
        '''
Current Plan:
$currentPlanJson

General User Feedback:
$feedback

DB Schema:
$dbSchema

Update the plan based on the feedback.
Address specific feedback for items if present.
Return ONLY a valid JSON list of objects: [{"description": "...", "tools": ["..."]}]
''';

    try {
      final response = await AIService.generateWithAttachments(
        prompt,
        [],
        generationContext: GenerationContext(
          values: {'type': 'agent_revise_plan'},
        ),
      );

      final tasks = _parseTasksFromJson(
        response,
        activeTools: [
          ..._nativeTools.map((t) => t.name),
          ..._externalTools.values.expand((l) => l.map((t) => t.name)),
        ],
      );
      _tasks = tasks.map((t) {
        t.status = AgentTaskStatus.pending;
        return t;
      }).toList();

      _currentThought = 'Plan revised. Waiting for review.';
      notifyListeners();
      return _tasks;
    } catch (e) {
      LoggerService.error('Failed to revise plan: $e');
      _currentThought = 'Failed to revise plan: $e';
      notifyListeners();
      rethrow;
    }
  }

  /// Executes the current list of tasks.
  Future<void> executePlan() async {
    if (_tasks.isEmpty) return;

    _isRunning = true;
    _currentThought = 'Starting execution...';
    notifyListeners();

    try {
      await _executeLoop();
    } catch (e) {
      LoggerService.error('Agent execution failure: $e');
      _currentThought = 'Error during execution: $e';
    } finally {
      _isRunning = false;
      notifyListeners();
    }
  }

  /// Legacy entry point for auto-execution, now supports tool injection
  Future<void> startObjective(
    String objective, {
    Map<String, List<McpTool>> activeTools = const {},
    ToolExecutor? executeTool,
    String? context,
    List<PlatformFile> contextAttachments = const [],
  }) async {
    _tasks.clear(); // Always clear tasks for new objective
    _finalAnswer = null;
    _finalMetadata = null;

    // _externalTools is set inside generatePlan now
    _isRunning = true;
    notifyListeners();

    try {
      await generatePlan(
        objective,
        activeTools: activeTools,
        executeTool: executeTool,
        context: context,
        contextAttachments: contextAttachments,
      );
      await executePlan();
    } finally {
      _isRunning = false;
      notifyListeners();
    }
  }

  void cancel() {
    _isRunning = false;
    _currentThought = 'Cancelled by user.';
    notifyListeners();
  }

  // _performTask moved to end of file

  // Intervention Methods

  /// Resumes a paused task, optionally increasing its turn limit.
  void resumeTask(String taskId, {bool increaseLimit = false}) {
    final task = _tasks.firstWhere((t) => t.id == taskId);
    if (increaseLimit) {
      task.maxTurns += 10;
    }
    // Restart execution
    executePlan();
  }

  /// Forces a task to conclude with its current observations.
  void concludeTask(String taskId) {
    final task = _tasks.firstWhere((t) => t.id == taskId);
    task.status = AgentTaskStatus.completed;
    task.result ??= "Manually concluded by user.";
    notifyListeners();
    executePlan(); // Move to next task
  }

  /// Aborts a task (and effectively the plan for now).
  void abortTask(String taskId) {
    final task = _tasks.firstWhere((t) => t.id == taskId);
    task.status = AgentTaskStatus.failed;
    task.result = "Aborted by user.";
    _isRunning = false;
    notifyListeners();
  }

  List<AgentTask> _parseTasksFromJson(
    String response, {
    required List<String> activeTools,
  }) {
    // Robust parsing for List
    String cleanResponse = response.trim();
    if (cleanResponse.startsWith('```json')) {
      cleanResponse = cleanResponse.replaceFirst('```json', '');
    }
    if (cleanResponse.startsWith('```')) {
      cleanResponse = cleanResponse.replaceFirst('```', '');
    }
    cleanResponse = cleanResponse.replaceAll(RegExp(r'```$'), '').trim();

    try {
      final List<dynamic> jsonList = jsonDecode(cleanResponse);
      return jsonList.map((item) {
        if (item is String) {
          return AgentTask(
            id: const Uuid().v4(),
            description: item,
            toolNames: [],
            allowedTools: activeTools,
          );
        }

        final map = item as Map<String, dynamic>;
        List<String> tools = [];
        if (map['tools'] != null) {
          tools = (map['tools'] as List).cast<String>();
        } else if (map['tool'] != null) {
          tools = [map['tool'] as String];
        }

        // Extract isFinalDeliverable flag (defaults to false if not present)
        final isFinalDeliverable = map['isFinalDeliverable'] == true;

        // Extract extractFindings flag (defaults to false if not present)
        final extractFindings = map['extractFindings'] == true;

        return AgentTask(
          id: const Uuid().v4(),
          description: map['description'] ?? "No description",
          toolNames: tools,
          allowedTools: activeTools,
          isFinalDeliverable: isFinalDeliverable,
          extractFindings: extractFindings,
        );
      }).toList();
    } catch (e) {
      LoggerService.error('Failed to parse JSON list: $e');
      return [];
    }
  }

  Future<void> _performTask(AgentTask task, String globalContext) async {
    // Check for max turns
    if (task.executionHistory.length / 2 >= task.maxTurns) {
      task.status = AgentTaskStatus.paused;
      task.result = "Max turns reached. Paused.";
      notifyListeners();
      return;
    }

    // If no tools AND not a final deliverable, simple thought step
    // Final deliverable tasks need LLM to synthesize even without tools
    if (task.toolNames.isEmpty && !task.isFinalDeliverable) {
      task.result = "Thought step completed.";
      task.status = AgentTaskStatus.completed;
      notifyListeners();
      return;
    }

    final int turn = (task.executionHistory.length / 2).floor() + 1;

    // We only execute ONE tool at a time in the ReAct loop per original design,
    // BUT the prompt might have assigned multiple tools to this `AgentTask`.
    // The `_performTask` function is effectively a mini-agent solving `task.description`.
    // The `task.toolNames` are suggestions or constraints.
    // Wait, if the plan said "Use Tool A and Tool B", we should probably just let the ReAct loop decide order.
    // The prompt passed to ReAct sees `Allowed Tools` (filtered by `task.allowedTools`).
    // So if the plan was specific about tools, we should probably restrict `task.allowedTools` to ONLY `task.toolNames`.
    // If `task.toolNames` is NOT empty, we restrict execution to those tools?

    List<NativeTool> allowedNativeFn() {
      if (task.toolNames.isEmpty) return _nativeTools;
      return _nativeTools
          .where((t) => task.toolNames.contains(t.name))
          .toList();
    }

    List<McpTool> allowedExternalFn() {
      final all = _externalTools.values.expand((x) => x).toList();
      if (task.toolNames.isEmpty) return all;
      return all.where((t) => task.toolNames.contains(t.name)).toList();
    }

    final currentAllowedNative = allowedNativeFn();
    final currentAllowedExternal = allowedExternalFn();

    // Fallback: If for some reason the planned tool isn't found in native/external,
    // we should alert or fail? For now, we proceed with what we found.

    final toolsDesc = [
      ...currentAllowedNative.map(
        (t) =>
            '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}',
      ),
      ...currentAllowedExternal.map(
        (t) =>
            '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}',
      ),
    ].join('\n');

    // Build special instructions for final deliverable tasks
    final deliverableInstructions = task.isFinalDeliverable
        ? '''

IMPORTANT: This is the FINAL DELIVERABLE task.
Your answer will be shown DIRECTLY to the user without further processing.
- Produce the complete, detailed output the user requested (report, analysis, etc.)
- Do NOT summarize - give the full deliverable
- Format with Markdown for readability
- Include all relevant data, citations, and findings from the context above

OUTPUT FORMAT (NO JSON for final deliverable):
Just write your complete report/deliverable directly in Markdown. Do NOT wrap it in JSON.
'''
        : '';

    // Use different format instructions based on whether this is a final deliverable
    final formatInstructions = task.isFinalDeliverable
        ? '''
FORMAT:
Since this is the FINAL DELIVERABLE, just write your complete response directly.
Do NOT use JSON format - output the full report/analysis in Markdown.
'''
        : '''
FORMAT:
My thought: ...

Then choose ONE action:
```json
{ "tool": "tool_name", "args": { ... } }
```
OR
```json
{ "think": "Detailed analysis or reasoning about data already in context" }
```
OR
```json
{ "spawn_subtask": { "description": "What the subtask should accomplish", "tools": ["tool1", "tool2"] } }
```
OR
```json
{ "answer": "Final summary when task is complete" }
```

ACTION GUIDANCE:
- **think**: Analyze/reason about data ALREADY in execution history - don't reload files
- **tool**: Fetch NEW data not yet in context
- **spawn_subtask**: Delegate complex sub-problems to a focused child task (max depth: ${kMaxSubtaskDepth})
  Use when: task is too complex, needs parallel investigation, or benefits from context isolation
- **answer**: Conclude when objective is satisfied

Current task depth: ${task.depth} / $kMaxSubtaskDepth
''';

    final prompt =
        '''
You are an intelligent agent working on a task.
Task Description: "${task.description}"

Global Context (Results from previous tasks):
$globalContext

Available Tools (You are restricted to these if specified in plan):
$toolsDesc

Execution History:
${task.executionHistory.map((h) => h.toString()).join('\n')}

## ITERATION PROTOCOL

After each action, evaluate:
1. Did I get what I needed? If yes, proceed to answer.
2. Are there gaps? Make another tool call OR spawn a subtask.
3. Is the problem complex? Consider spawning subtasks for focused investigation.

You may call tools MULTIPLE TIMES per task if needed.
Don't settle for incomplete information when tools are available.

## RESPONSE FORMAT (preserved for UI display)

Always structure your response as:
1. "My thought: [your reasoning about what to do next]"
2. ONE action in JSON format (tool, think, spawn_subtask, or answer)

This format is shown to the user to help them understand your reasoning.

INSTRUCTIONS:
1. Analyze the context and history.
2. Formulate a CLEAR THOUGHT about what to do next.
3. Choose ONE action:
   - "tool": Execute a tool to fetch NEW data
   - "think": Analyze data ALREADY in context (don't reload)
   - "spawn_subtask": Delegate complex work to a focused child task
   - "answer": Complete the task when objective is satisfied
$deliverableInstructions
$formatInstructions
''';

    try {
      final response = await AIService.generateWithAttachments(
        prompt,
        [],
        generationContext: GenerationContext(
          values: {'type': 'agent_step', 'taskId': task.id, 'turn': turn},
        ),
      );

      // ... Parsing Logic (Similar to before but inside this function) ...
      // Re-using existing ReAct parsing logic but ensuring it matches new flow

      // SPECIAL HANDLING: For final deliverable tasks, use the full response as the answer
      // (no JSON parsing needed since we told LLM to output directly in Markdown)
      if (task.isFinalDeliverable) {
        // Strip any "My thought:" prefix if present
        String result = response;
        final thoughtPrefix = RegExp(r'^My thought:.*?\n\n', dotAll: true);
        result = result.replaceFirst(thoughtPrefix, '').trim();

        task.result = result;
        task.status = AgentTaskStatus.completed;
        task.executionHistory.add('Turn $turn:');
        task.executionHistory.add('Final deliverable produced.');

        if (task.contextNodeId != null) {
          _contextManager
              .getContext(task.contextNodeId!)
              ?.log('Turn $turn - Final deliverable produced');
        }

        notifyListeners();
        return;
      }

      // Extract thought and JSON action
      String? jsonStr;
      String thought = '';

      // Method 1: Look for ```json ... ``` block (most reliable)
      final jsonBlockMatch = RegExp(
        r'```json\s*(\{.*?\})\s*```',
        dotAll: true,
      ).firstMatch(response);

      if (jsonBlockMatch != null) {
        jsonStr = jsonBlockMatch.group(1);
        thought = response.substring(0, jsonBlockMatch.start).trim();
      } else {
        // Method 2: Find JSON object with expected action keys
        // This avoids matching template placeholders like {cid} or {BVID}
        final jsonStartMatch = RegExp(
          r'\{\s*"(?:tool|answer|think|spawn_subtask)"\s*:',
        ).firstMatch(response);

        if (jsonStartMatch != null) {
          thought = response.substring(0, jsonStartMatch.start).trim();
          // Extract full JSON by finding matching closing brace
          final startIdx = jsonStartMatch.start;
          int braceCount = 0;
          int? endIdx;
          for (int i = startIdx; i < response.length; i++) {
            if (response[i] == '{') {
              braceCount++;
            } else if (response[i] == '}') {
              braceCount--;
              if (braceCount == 0) {
                endIdx = i + 1;
                break;
              }
            }
          }
          if (endIdx != null) {
            jsonStr = response.substring(startIdx, endIdx);
          }
        }
      }

      if (thought.startsWith('My thought:')) {
        thought = thought.replaceFirst('My thought:', '').trim();
      }
      _currentThought = thought.isNotEmpty ? thought : "Executing...";
      notifyListeners();

      task.executionHistory.add('Turn $turn:');
      task.executionHistory.add('Thought: $_currentThought');

      // Log to hierarchical context
      if (task.contextNodeId != null) {
        _contextManager
            .getContext(task.contextNodeId!)
            ?.log('Turn $turn - Thought: $_currentThought');
      }

      if (jsonStr == null) {
        // LLM-based verdict extraction: ask LLM to classify its own response
        // using tag format to avoid JSON parsing issues
        final verdictPrompt =
            '''
The following response was produced but does not conform to the expected JSON format.
Analyze the content and determine the intent:

---
$response
---

Was this response:
1. A completed ANSWER to the task?
2. A TOOL call request that wasn't properly formatted?
3. A THINK step (analysis/reasoning) that should continue?

Respond ONLY in this exact format (no JSON):
<verdict>answer|tool|think</verdict>
<content>
The actual content (answer text, or tool call details, or reasoning)
</content>
''';

        try {
          final verdictResponse = await AIService.generateWithAttachments(
            verdictPrompt,
            [],
            generationContext: GenerationContext(
              values: {'type': 'agent_verdict', 'taskId': task.id},
            ),
          );

          final verdictMatch = RegExp(
            r'<verdict>(answer|tool|think)</verdict>',
          ).firstMatch(verdictResponse);
          final contentMatch = RegExp(
            r'<content>\s*([\s\S]*?)\s*</content>',
          ).firstMatch(verdictResponse);

          if (verdictMatch != null && contentMatch != null) {
            final verdict = verdictMatch.group(1);
            final content = contentMatch.group(1)?.trim() ?? '';

            if (verdict == 'answer' && content.isNotEmpty) {
              task.result = content;
              task.status = AgentTaskStatus.completed;
              task.executionHistory.add('Answer extracted via verdict check.');
              notifyListeners();
              return;
            } else if (verdict == 'think') {
              task.executionHistory.add('Analysis: $content');
              // Continue loop
              return;
            }
            // 'tool' case: content should describe what was intended
            task.executionHistory.add(
              'Tool intent detected but malformed: $content',
            );
          }
        } catch (e) {
          LoggerService.error('Verdict extraction failed: $e');
        }

        task.executionHistory.add('Error: No JSON action found in response.');
        return;
      }

      Map<String, dynamic> decision;
      try {
        decision = jsonDecode(jsonStr);
      } catch (e) {
        task.executionHistory.add("Error: Invalid JSON: $e");
        return;
      }

      if (decision.containsKey('answer')) {
        task.result = decision['answer'];
        task.status = AgentTaskStatus.completed;
        notifyListeners();
        return;
      }

      // Handle "think" action - pure reasoning on existing context
      if (decision.containsKey('think')) {
        final thinkContent = decision['think'] as String?;
        if (thinkContent != null && thinkContent.isNotEmpty) {
          task.executionHistory.add('Analysis: $thinkContent');
          _contextManager
              .getContext(task.contextNodeId ?? '')
              ?.log('Analysis: $thinkContent');
          _currentThought =
              'Analyzing: ${thinkContent.length > 100 ? '${thinkContent.substring(0, 100)}...' : thinkContent}';
          notifyListeners();
          // Continue loop without calling a tool
          return;
        }
      }

      // Handle "spawn_subtask" action - delegate work to a child task
      if (decision.containsKey('spawn_subtask')) {
        final subtaskSpec = decision['spawn_subtask'] as Map<String, dynamic>?;
        if (subtaskSpec != null) {
          await _handleSpawnSubtask(task, subtaskSpec);
          return; // Subtask spawned, continue loop to wait for it
        }
      }

      final toolName = decision['tool'] as String?;
      final args = decision['args'] as Map<String, dynamic>? ?? {};

      if (toolName == null) {
        task.executionHistory.add("Error: Missing 'tool' or 'answer' key.");
        return;
      }

      // Execute Tool
      task.executionHistory.add('Action: Call $toolName');
      _contextManager
          .getContext(task.contextNodeId ?? '')
          ?.log(
            'Action: Calling tool $toolName with args: ${jsonEncode(args)}',
          );
      notifyListeners();

      dynamic result;
      try {
        // Try Native
        final nativeTool = _nativeTools.firstWhere(
          (t) => t.name == toolName,
          orElse: () => _UnknownTool(),
        );
        if (nativeTool is! _UnknownTool) {
          result = await nativeTool.execute(args);
        } else {
          // Try External
          String? serviceName;
          for (final entry in _externalTools.entries) {
            if (entry.value.any((t) => t.name == toolName)) {
              serviceName = entry.key;
              break;
            }
          }
          if (serviceName != null) {
            final generationContext = GenerationContext(
              values: {'type': 'agent_tool_exec'},
            );
            // Use injected executor if available (supports both MCP and local AI tools)
            if (_toolExecutor != null) {
              result = await _toolExecutor!(
                serviceName,
                toolName,
                args,
                generationContext,
              );
            } else {
              // Fallback: MCP-only execution (legacy behavior)
              final endpoints = await McpService.getEndpoints();
              final ids = endpoints.map((e) => e.id).toList();
              result = await McpToolIntegrationService.executeToolCall(
                serviceName: serviceName,
                toolName: toolName,
                parameters: args,
                enabledEndpointIds: ids,
                generationContext: generationContext,
              );
            }
          } else {
            throw "Tool $toolName not found.";
          }
        }
      } catch (e) {
        result = "Error executing $toolName: $e";
      }

      task.executionHistory.add("Observation: $result");
      // Log observation to hierarchical context
      _contextManager
          .getContext(task.contextNodeId ?? '')
          ?.log('Observation: $result');
      notifyListeners();
    } catch (e) {
      LoggerService.error("Agent Loop Error: $e");
      task.executionHistory.add("Error: Internal Agent Loop Error: $e");
    }
  }

  /// Handles LLM request to spawn a subtask dynamically.
  Future<void> _handleSpawnSubtask(
    AgentTask parentTask,
    Map<String, dynamic> spec,
  ) async {
    // 1. Validate depth limit
    if (parentTask.depth >= kMaxSubtaskDepth) {
      parentTask.executionHistory.add(
        'Cannot spawn subtask: maximum depth ($kMaxSubtaskDepth) reached. Use "think" to analyze instead.',
      );
      _currentThought = 'Subtask depth limit reached';
      notifyListeners();
      return;
    }

    // 2. Extract subtask details
    final description = spec['description'] as String?;
    final toolsList = spec['tools'] as List?;
    final tools = toolsList?.cast<String>() ?? <String>[];

    if (description == null || description.isEmpty) {
      parentTask.executionHistory.add(
        'Cannot spawn subtask: missing description',
      );
      return;
    }

    // 3. Create subtask with parent linkage
    final subtask = AgentTask(
      id: const Uuid().v4(),
      description: description,
      parentTaskId: parentTask.id,
      depth: parentTask.depth + 1,
      isSpawnedDynamically: true,
      toolNames: tools,
      allowedTools: tools.isEmpty ? parentTask.allowedTools : tools,
      maxTurns: parentTask.maxTurns,
    );

    // 4. Create context for subtask with compacted parent context
    final parentContext = _contextManager.getContext(
      parentTask.contextNodeId ?? '',
    );
    if (parentContext != null) {
      final childContext = _contextManager.createChildContext(
        parent: parentContext,
        objective: description,
        allowedTools: subtask.allowedTools,
      );
      subtask.contextNodeId = childContext.id;

      // Add compacted parent summary to child context (objective-aware)
      try {
        final compactedContext = await _compactContextForSubtask(
          parentContext,
          description,
        );
        childContext.log('Parent context summary:\n$compactedContext');
      } catch (e) {
        LoggerService.error('Failed to compact context for subtask: $e');
        childContext.log('Parent objective: ${parentContext.objective}');
      }
    }

    // 5. Track spawned subtask
    parentTask.spawnedSubtaskIds.add(subtask.id);

    // 6. Insert subtask into queue (right after parent's current position)
    final parentIndex = _tasks.indexOf(parentTask);
    _tasks.insert(parentIndex + 1, subtask);

    // 7. Log and notify
    parentTask.executionHistory.add(
      'Spawned subtask [depth=${subtask.depth}]: ${subtask.description}',
    );
    _currentThought = 'Spawned subtask: ${subtask.description}';
    notifyListeners();
  }

  /// Compacts parent context for subtask consumption.
  /// The compaction is objective-aware to preserve relevant information.
  Future<String> _compactContextForSubtask(
    ContextNode parentContext,
    String subtaskObjective,
  ) async {
    final prompt =
        '''
You are handing off work to a colleague who will handle this subtask:
"$subtaskObjective"

Provide a CONCISE briefing (max 500 words) RELEVANT to the subtask:
1. What has been discovered that's relevant to the subtask
2. Key data/URLs/findings the subtask will need
3. What NOT to repeat (already tried approaches)

Current execution log:
${parentContext.executionLog.join('\n')}

Write a focused briefing for the subtask:
''';

    return await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(
        values: {'type': 'subtask_briefing'},
      ),
    );
  }
}

class _UnknownTool implements NativeTool {
  @override
  String get name => 'unknown';
  @override
  String get description => 'Legacy placeholder';
  @override
  Map<String, dynamic> get inputSchema => {};
  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    throw UnimplementedError();
  }
}
