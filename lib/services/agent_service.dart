import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/agent_task.dart';
import '../models/generation_context.dart';
import '../models/mcp_endpoint.dart';
import 'tools/note_tools.dart';
import 'ai_service.dart';
import 'logger_service.dart';
import 'mcp_tool_integration_service.dart';
import 'mcp_service.dart';

class AgentService extends ChangeNotifier {
  // State
  List<AgentTask> _tasks = [];
  Map<String, List<McpTool>> _externalTools = {};
  bool _isRunning = false;
  String? _currentThought;
  String? _finalAnswer;

  List<AgentTask> get tasks => List.unmodifiable(_tasks);
  Map<String, List<McpTool>> get externalTools =>
      Map.unmodifiable(_externalTools);
  bool get isRunning => _isRunning;
  String? get currentThought => _currentThought;
  String? get finalAnswer => _finalAnswer;

  // ... (nativeTools and dbSchema definitions remain the same) ...

  /// ExecuteLoop with Final Summary Generation
  Future<void> _executeLoop() async {
    final StringBuffer globalContext = StringBuffer();

    // Rebuild context from already completed tasks if we are resuming?
    for (final t in _tasks) {
      if (t.status == AgentTaskStatus.completed) {
        globalContext.writeln('Task: ${t.description}');
        globalContext.writeln('Result: ${t.result}');
        globalContext.writeln('---');
      }
    }

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

      // Update status
      task.status = AgentTaskStatus.inProgress;
      _currentThought = 'Working on: ${task.description}';
      notifyListeners();

      try {
        await _performTask(task, globalContext.toString());

        if (task.status == AgentTaskStatus.paused) {
          // Task paused (max turns reached). Stop execution loop.
          _isRunning = false;
          _currentThought = 'Task paused: ${task.description}';
          notifyListeners();
          return;
        }

        task.status = AgentTaskStatus.completed;

        // Append result to global context for future tasks
        globalContext.writeln('Task: ${task.description}');
        globalContext.writeln('Result: ${task.result}');
        globalContext.writeln('---');
      } catch (e) {
        task.status = AgentTaskStatus.failed;
        task.result = 'Error: $e';
        // Even on failure, log it so next tasks know
        globalContext.writeln('Task: ${task.description}');
        globalContext.writeln('Failed: $e');
        globalContext.writeln('---');
      }
      notifyListeners();
    }

    if (_tasks.every((t) => t.status == AgentTaskStatus.completed)) {
      _currentThought = 'Generating final summary...';
      notifyListeners();

      try {
        await _generateFinalSummary(globalContext.toString());
        _currentThought = 'All tasks completed.';
      } catch (e) {
        // Fallback if summary fails
        _finalAnswer =
            "Execution finished, but failed to generate summary. See task details.";
        LoggerService.error('Failed to generate summary: $e');
      }
    }
  }

  Future<void> _generateFinalSummary(String globalContext) async {
    // We assume the objective is implicit in the context or we could pass it down.
    // Ideally we should store the initial objective.
    // For now we ask the LLM to summarize the findings.

    final prompt =
        '''
You have completed a series of tasks to achieve a user objective.
Here is the execution log (Context):
$globalContext

Based on the above results, provide a final, concise, and helpful response to the user.
Answer their original request directly.
Format with Markdown.
''';

    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(values: {'type': 'agent_summary'}),
    );

    _finalAnswer = response;
    notifyListeners();
  }

  // Tools
  // Tools
  final List<NativeTool> _nativeTools = [
    NoteSearchTool(),
    NoteReadTool(),
    RunSqlTool(),
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

  // DB Schema for Agent Context
  static const String _dbSchema = '''
Table: notes
- id (TEXT, PK): Unique identifier for the note.
- title (TEXT): The title of the note.
- content (TEXT): The markdown content of the note.
- type (TEXT): 'note' or 'task'.
- createdAt (INTEGER): Creation timestamp (millis).
- updatedAt (INTEGER): Last update timestamp (millis).
- recurrenceRule (TEXT): JSON string for recurrence (e.g., {"frequency":"daily"}).

Table: tags
- id (TEXT, PK): Unique identifier for the tag.
- name (TEXT): The display name of the tag.

Table: note_tags
- noteId (TEXT, FK): Foreign key to notes.id.
- tagId (TEXT, FK): Foreign key to tags.id.

Table: conversations
- id (TEXT, PK): Unique identifier.
- title (TEXT): Conversation title.
- noteIds (TEXT): JSON array of string note IDs linked to this conversation.
- createdAt (INTEGER): Creation timestamp.

Table: tag_filters
- id (TEXT, PK): Unique identifier.
- name (TEXT): Name of the saved filter/view.
- includeText (TEXT): Text query to match.
- includeTags (TEXT): JSON array of tag IDs to include.
- excludeTags (TEXT): JSON array of tag IDs to exclude.
- noteTypes (TEXT): JSON array of note types ('note', 'task') to include.
''';

  /// Generates an initial plan based on the objective.
  /// Updates internal state and returns the tasks.
  Future<List<AgentTask>> generatePlan(
    String objective, {
    Map<String, List<McpTool>> activeTools = const {},
  }) async {
    _externalTools = activeTools;
    _currentThought = 'Generating plan...';
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

    final prompt =
        '''
You are an intelligent agent that plans and executes tasks to solve an objective.
Objective: "$objective"

Available Tools:
$nativeToolsDesc
$externalToolsDesc

Database Schema (for RunSqlTool):
$_dbSchema

Break this down into a step-by-step plan.
Each step should specify WHICH tool to use.
Return ONLY a valid JSON list of objects with "description" and "tool" fields.
Example:
[
  {"description": "Find notes about...", "tool": "NoteSearchTool"},
  {"description": "Read valid notes...", "tool": "NoteReadTool"}
]
''';

    try {
      final response = await AIService.generateWithAttachments(
        prompt,
        [],
        generationContext: GenerationContext(values: {'type': 'agent_plan'}),
      );

      final List<dynamic> jsonList = _parseJsonList(response);
      final allActiveTools = getAllToolNames();

      _tasks = jsonList.map((item) {
        if (item is String) {
          return AgentTask(
            id: const Uuid().v4(),
            description: item,
            status: AgentTaskStatus.pending,
            allowedTools: allActiveTools,
          );
        }
        final map = item as Map<String, dynamic>;
        return AgentTask(
          id: const Uuid().v4(),
          description: map['description'] as String,
          toolName: map['tool'] as String?,
          status: AgentTaskStatus.pending,
          allowedTools: allActiveTools,
        );
      }).toList();

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
              'tool': t.toolName,
              if (t.userComment != null && t.userComment!.isNotEmpty)
                'feedback': t.userComment,
            },
          )
          .toList(),
    );

    final prompt =
        '''
Current Plan:
$currentPlanJson

General User Feedback:
$feedback

DB Schema:
$_dbSchema

Update the plan based on the feedback.
Address specific feedback for items if present.
Return ONLY a valid JSON list of objects: [{"description": "...", "tool": "..."}]
''';

    try {
      final response = await AIService.generateWithAttachments(
        prompt,
        [],
        generationContext: GenerationContext(
          values: {'type': 'agent_revise_plan'},
        ),
      );

      final List<dynamic> jsonList = _parseJsonList(response);

      _tasks = jsonList.map((item) {
        if (item is String) {
          return AgentTask(
            id: const Uuid().v4(),
            description: item,
            status: AgentTaskStatus.pending,
          );
        }
        final map = item as Map<String, dynamic>;
        return AgentTask(
          id: const Uuid().v4(),
          description: map['description'] as String,
          toolName: map['tool'] as String?,
          status: AgentTaskStatus.pending,
        );
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
  }) async {
    if (_isRunning) {
      _tasks.clear();
    }
    // _externalTools is set inside generatePlan now
    _isRunning = true;
    notifyListeners();

    try {
      await generatePlan(objective, activeTools: activeTools);
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

  Future<void> _performTask(AgentTask task, String globalContext) async {
    // ReAct Loop
    // logic checks task.executionHistory length vs task.maxTurns

    while (task.executionHistory.length / 2 < task.maxTurns) {
      if (task.status == AgentTaskStatus.paused) {
        // Stop execution if paused
        notifyListeners();
        return;
      }

      final int turn = (task.executionHistory.length / 2).floor() + 1;

      // 1. Construct Prompt with History
      // Filter tools based on allowedTools if set
      final allowedNativeTools = task.allowedTools.isEmpty
          ? _nativeTools
          : _nativeTools.where((t) => task.allowedTools.contains(t.name));

      final allExternalTools = _externalTools.values.expand((l) => l).toList();
      final allowedExternalTools = task.allowedTools.isEmpty
          ? allExternalTools
          : allExternalTools.where((t) => task.allowedTools.contains(t.name));

      final toolsDesc = [
        ...allowedNativeTools.map(
          (t) =>
              '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}',
        ),
        ...allowedExternalTools.map(
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

Available Tools:
$toolsDesc

Execution History (Your previous steps):
${task.executionHistory.map((h) => h.toString()).join('\n')}

INSTRUCTIONS:
1. Analyze the Global Context and Execution History.
2. Formulate a CLEAR THOUGHT about what to do next.
3. Select a tool to execute (or use "answer" fallback if done).
4. If you have sufficient information to complete the task, your "Tool" action should call the `answer` tool (conceptually) by outputting the final answer in the JSON.
   (Note: If you have a specific answer or conclusion, just output it as the content of the "answer" tool/key or simply mark task as complete if the UI allows).
   ACTUALLY, to finish the task, you MUST use the special "answer" action:
   { "answer": "Your final summary of what you did and the result." }

FORMAT:
You MUST provide your output in two distinct parts:
My thought: <Your reasoning here>
Tool:
```json
{ "tool": "tool_name", "args": { ... } }
```
OR for the final answer:
My thought: <Your reasoning>
Tool:
```json
{ "answer": "Your final explanation..." }
```

CRITICAL:
- ALWAYS start with "My thought:".
- ALWAYS execute ONE tool per turn.
- If you are stuck, use "My thought: I am stuck because..." and then try a different approach or ask for user help via "answer".
''';

      try {
        // 2. Call LLM
        final response = await AIService.generateWithAttachments(
          prompt,
          [], // No attachments for the agent logic itself yet
          generationContext: GenerationContext(
            values: {'type': 'agent_step', 'taskId': task.id, 'turn': turn},
          ),
        );

        // 3. Parse Response (Thought + JSON)
        String thought = '';
        Map<String, dynamic> decision = {};

        // Regex to capture "My thought: ... Tool: ... json ..."
        // We make it robust: Look for "My thought:" grouping and then a JSON block key.
        // Actually, let's just look for the last JSON block and treat everything before it as thought/context.

        final jsonMatch = RegExp(r'\{.*\}', dotAll: true).firstMatch(response);
        // Better regex to find the JSON block specifically associated with the tool
        // often inside ```json ... ```
        final codeBlockMatch = RegExp(
          r'```json\s*(\{.*?\})\s*```',
          dotAll: true,
        ).firstMatch(response);
        final rawJsonMatch = RegExp(
          r'(\{.*\})',
          dotAll: true,
        ).firstMatch(response);

        String? jsonStr;
        if (codeBlockMatch != null) {
          jsonStr = codeBlockMatch.group(1);
          // Thought is everything before the code block
          thought = response.substring(0, codeBlockMatch.start).trim();
        } else if (rawJsonMatch != null) {
          jsonStr = rawJsonMatch.group(1);
          // Thought is everything before the JSON
          thought = response.substring(0, rawJsonMatch.start).trim();
        }

        // Clean up "My thought:" prefix if present
        if (thought.startsWith('My thought:')) {
          thought = thought.replaceFirst('My thought:', '').trim();
        }
        // If thought is empty (LLM forgot it), use a placeholder
        if (thought.isEmpty) thought = "Executing tool...";

        // Update UI with thought immediately
        _currentThought = thought;
        notifyListeners(); // Refresh UI to show "My thought: ..."

        if (jsonStr != null) {
          try {
            decision = jsonDecode(jsonStr);
          } catch (e) {
            // Try rudimentary fix if flexible parsing needed, else throw
            throw FormatException("Invalid JSON in response.");
          }
        } else {
          throw FormatException("No JSON tool execution found.");
        }

        // 4. Update History
        task.executionHistory.add('Turn $turn:');
        task.executionHistory.add('Thought: $thought');
        // We don't add the full JSON to history to save tokens, just the decision summary
        // task.executionHistory.add('Action: $decision');

        // 5. Execute Tool
        if (decision.containsKey('answer')) {
          task.result = decision['answer'];
          task.status = AgentTaskStatus.completed;
          task.executionHistory.add(
            'Result: Task Completed. Answer: ${task.result}',
          );
          notifyListeners();
          return; // Task Done
        }

        final toolName = decision['tool'] as String?;
        final args = decision['args'] as Map<String, dynamic>? ?? {};

        if (toolName == null) {
          task.executionHistory.add(
            'Error: System: Invalid format. You must provide a "My thought:" line followed by a "Tool:" line containing the JSON action.',
          );
          continue; // Retry
        }

        task.executionHistory.add('Action: Call $toolName with $args');
        notifyListeners(); // Update UI

        dynamic result;
        try {
          // Check Native Tools
          final nativeTool = _nativeTools.firstWhere(
            (t) => t.name == toolName,
            orElse: () => throw Exception('Tool not found'),
          );
          // It's a native tool
          // Check allowed tools constraint? (Already filtered in prompt, but good to check)
          if (task.allowedTools.isNotEmpty &&
              !task.allowedTools.contains(toolName)) {
            throw Exception("Tool '$toolName' is not allowed for this task.");
          }

          result = await nativeTool.execute(args);
        } catch (e) {
          // Check External Tools
          String? serviceName;
          for (final entry in _externalTools.entries) {
            if (entry.value.any((t) => t.name == toolName)) {
              serviceName = entry.key;
              break;
            }
          }

          if (serviceName != null) {
            // Check allowed constraint
            if (task.allowedTools.isNotEmpty &&
                !task.allowedTools.contains(toolName)) {
              result = "Error: Tool '$toolName' is not allowed for this task.";
            } else {
              final endpoints = await McpService.getEndpoints();
              final enabledEndpointIds = endpoints.map((e) => e.id).toList();

              result = await McpToolIntegrationService.executeToolCall(
                serviceName: serviceName,
                toolName: toolName,
                parameters: args,
                enabledEndpointIds: enabledEndpointIds,
                generationContext: GenerationContext(
                  values: {'type': 'agent_tool_exec'},
                ),
              );
            }
          } else {
            result = 'Error: Tool "$toolName" not found.';
          }
        }

        // 6. Record Observation
        task.executionHistory.add('Observation: $result');
        notifyListeners();
      } catch (e) {
        LoggerService.error('Agent Turn Error: $e');
        task.executionHistory.add(
          'Error: System: Invalid format or execution error. You must provide a "My thought:" line followed by a "Tool:" line containing the JSON action. Error details: $e',
        );
        // Backoff?
      }
    }

    // Max turns reached - Wait, we are inside the method.
    // If the loop finishes without completion
    if (task.status != AgentTaskStatus.completed) {
      task.status = AgentTaskStatus.paused; // Pause instead of fail
      task.result = "Max turns reached. Paused for user intervention.";
      notifyListeners();
    }
  }

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

  List<dynamic> _parseJsonList(String response) {
    // Robust parsing for List
    try {
      final jsonMatch = RegExp(r'\[.*\]', dotAll: true).firstMatch(response);
      final jsonStr = jsonMatch?.group(0) ?? response;

      final cleaned = jsonStr
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      return jsonDecode(cleaned);
    } catch (e) {
      LoggerService.error('Failed to parse JSON list: $e');
      return [];
    }
  }
}
