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

  /// Gets the context manager for external access.
  ContextManagerService get contextManager => _contextManager;

  /// Gets the current objective.
  String? get currentObjective => _currentObjective;

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
          final scopedContext = _contextManager.buildContextForNode(
            taskContext,
          );
          await _performTask(task, scopedContext);

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
          try {
            task.condensedSummary = await _contextManager.generateFinalSummary(
              taskContext,
            );
            taskContext.log('Task completed with result: ${task.result}');
          } catch (e) {
            LoggerService.error('Failed to generate task summary: $e');
            task.condensedSummary = task.result;
            taskContext.status = ContextNodeStatus.completed;
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

    // Generate final summary using root context
    if (_tasks.every((t) => t.status == AgentTaskStatus.completed)) {
      _currentThought = 'Generating final summary...';
      notifyListeners();

      try {
        final rootCtx = _contextManager.rootContext;
        final contextSummary = rootCtx != null
            ? _contextManager.buildContextForNode(rootCtx)
            : _buildLegacyContext();
        await _generateFinalSummary(contextSummary);
        _currentThought = 'All tasks completed.';
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

  // Tools
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

IMPORTANT CONTEXT ON NOTE ORGANIZATION:
- Notes are organized using hashtags (e.g., #work, #ideas). Think of these tags as a flexible file system where a note can live in multiple "folders" simultaneously.
- "Tag Filters" are saved views or "virtual folders" defined by includes/excludes of tags. These represent the user's explicit organizational structure.
- The `ls` tool lists these "virtual folders".

STRATEGY HINT:
- If you are exploring, trying to understand the user's note structure, or don't know where to look: USE THE `ls` TOOL FIRST. It gives you the "directory listing" of the user's brain.
- In addition to `ls`, you can query the tags table for all user and auto-generated tags to determine their relevance to your search.
- Only jump to `search_notes` if you have a specific keyword or if `ls` doesn't provide enough leads.

Objective: "$objective"
$contextSection
Available Tools:
$nativeToolsDesc
$externalToolsDesc

Database Schema (for RunSqlTool):
$dbSchema

Break this down into a step-by-step plan.
Each step can specify ONE OR MORE tools to use to accomplish that step.
For example, to list things and then read them, you can have separate steps or combined logic.
Return ONLY a valid JSON list of objects:
[
  {
    "description": "Step description",
    "tools": ["tool_name_1", "tool_name_2"]
  }
]
Example:
[
  {"description": "Search for notes", "tools": ["search_notes"]},
  {"description": "Read notes and summarize", "tools": ["read_note"]}
]
If no tools are needed for a step (e.g. analysis), use an empty list: "tools": [].
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

        return AgentTask(
          id: const Uuid().v4(),
          description: map['description'] ?? "No description",
          toolNames: tools,
          allowedTools: activeTools,
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

    // If no tools, simple thought step
    if (task.toolNames.isEmpty) {
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

INSTRUCTIONS:
1. Analyze the context and history.
2. Formulate a CLEAR THOUGHT.
3. Select a tool to execute (or use "answer" if done).
   If the plan assigned multiple tools, you generally execute them one by one in subsequent turns until the task is satisfied.
   
FORMAT:
My thought: ...
Tool:
```json
{ "tool": "tool_name", "args": { ... } }
```
OR
```json
{ "answer": "Final summary..." }
```
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

      String thought = '';
      String? jsonStr;

      // Extract thought
      final jsonMatch = RegExp(
        r'```json\s*(\{.*?\})\s*```',
        dotAll: true,
      ).firstMatch(response);
      final altJsonMatch = RegExp(
        r'(\{.*\})',
        dotAll: true,
      ).firstMatch(response);

      if (jsonMatch != null) {
        jsonStr = jsonMatch.group(1);
        thought = response.substring(0, jsonMatch.start).trim();
      } else if (altJsonMatch != null) {
        jsonStr = altJsonMatch.group(1);
        thought = response.substring(0, altJsonMatch.start).trim();
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
        task.executionHistory.add("Error: No JSON action found in response.");
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
