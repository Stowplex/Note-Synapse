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
- id (TEXT, PK)
- title (TEXT)
- content (TEXT)
- type (TEXT: 'note' or 'task')
- createdAt (INTEGER)
- updatedAt (INTEGER)
- recurrenceRule (TEXT, JSON)

Table: tags
- id (TEXT, PK)
- name (TEXT)

Table: note_tags
- noteId (TEXT, FK)
- tagId (TEXT, FK)

Table: conversations
- id (TEXT, PK)
- title (TEXT)
- noteIds (TEXT, JSON array)
- createdAt (INTEGER)
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
      final int turn = (task.executionHistory.length / 2).floor() + 1;

      // 1. Construct Prompt with History
      // Filter tools based on allowedTools if set
      final allowedNativeTools = task.allowedTools.isEmpty
          ? _nativeTools
          : _nativeTools.where((t) => task.allowedTools.contains(t.name));

      final allExternalTools = _externalTools.values.expand((l) => l).toList();
      final allowedExternalTools = task.allowedTools.isEmpty
          ? allExternalTools
          : allExternalTools
                .where((t) => task.allowedTools.contains(t.name))
                .toList();

      final nativeToolsDesc = allowedNativeTools
          .map(
            (t) =>
                '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}',
          )
          .join('\n');

      final externalToolsDesc = allowedExternalTools.isNotEmpty
          ? '\nExternal Tools:\n' +
                allowedExternalTools
                    .map(
                      (t) =>
                          '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}',
                    )
                    .join('\n')
          : '';

      final prompt =
          '''
Current Task: ${task.description}

Objective Context (Findings from previous tasks):
$globalContext

Available Tools:
$nativeToolsDesc$externalToolsDesc

DB Schema:
$_dbSchema

History (Actions in this task):
${task.executionHistory.isEmpty ? "None" : task.executionHistory.join('\n')}

Instructions:
1. If you have enough info, return {"answer": "..."}.
2. If you need more info (or previous tool failed), use a tool.
3. If using RunSqlTool, ensure columns exist in DB Schema (e.g. use note_tags for tags, NOT notes.tags).
4. Do NOT stop unless you have found the answer or completed the action.
5. If you are stuck, return {"answer": "I am stuck..."} to ask user for help.

Decide what to do.
First, explain your reasoning (Thought).
Then, provide the JSON block for the action.

Example:
I see that the previous search failed. I will try a broader SQL query.
```json
{"tool": "RunSqlTool", "args": {"query": "..."}}
```
''';

      final response = await AIService.generateWithAttachments(
        prompt,
        [],
        generationContext: GenerationContext(values: {'type': 'agent_act'}),
      );

      // Parse Response
      String? thought;
      Map<String, dynamic> decision;
      try {
        final jsonMatch = RegExp(r'\{.*\}', dotAll: true).firstMatch(response);
        if (jsonMatch != null) {
          final jsonStr = jsonMatch.group(0)!;

          // Extract thought (text before JSON)
          if (jsonMatch.start > 0) {
            thought = response.substring(0, jsonMatch.start).trim();
            if (thought.isNotEmpty) {
              _currentThought = thought;
              notifyListeners();
              task.executionHistory.add('Thought: $thought');
            }
          }

          final cleaned = jsonStr
              .replaceAll('```json', '')
              .replaceAll('```', '')
              .trim();
          decision = jsonDecode(cleaned);
        } else {
          throw FormatException('No JSON found');
        }
      } catch (e) {
        task.executionHistory.add(
          'System: Invalid JSON format. Return ONLY JSON.',
        );
        continue;
      }

      if (decision.containsKey('tool')) {
        final toolName = decision['tool'];
        // FIX: Safe cast for args
        final args = (decision['args'] as Map<String, dynamic>?) ?? {};

        try {
          // Update thought to show action execution (Persistent)
          final executionMsg = '\n\nExecuting $toolName (Turn $turn)...';
          _currentThought = (_currentThought ?? '') + executionMsg;
          notifyListeners();

          dynamic result;

          // Check Native Tools
          if (_nativeTools.any((t) => t.name == toolName)) {
            final tool = _nativeTools.firstWhere((t) => t.name == toolName);
            result = await tool.execute(args);
          } else {
            // Check External Tools
            // Find which service contains the tool
            String? serviceName;
            for (final entry in _externalTools.entries) {
              if (entry.value.any((t) => t.name == toolName)) {
                serviceName = entry.key;
                break;
              }
            }

            if (serviceName != null) {
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
            } else {
              throw Exception('Unknown tool: $toolName');
            }
          }

          final resultStr = jsonEncode(result);

          // Add to history
          task.executionHistory.add('Action: $toolName');
          task.executionHistory.add('Params: $args');

          // Truncate result if too long to save context
          final truncatedResult = resultStr.length > 2000
              ? '${resultStr.substring(0, 2000)}... (truncated)'
              : resultStr;
          task.executionHistory.add('Observation: $truncatedResult');

          // Loop continues...
        } catch (e) {
          task.executionHistory.add('Action: $toolName');
          task.executionHistory.add('Error: $e');
        }
      } else if (decision.containsKey('answer')) {
        task.result = decision['answer'];
        task.status = AgentTaskStatus.completed;
        return;
      } else {
        task.executionHistory.add(
          'System: Invalid JSON. Must contain "tool" or "answer".',
        );
      }
    }

    // If we exit loop without "answer", it's a failure or pause.
    task.result = 'Max execution turns (${task.maxTurns}) reached.';
    task.status = AgentTaskStatus.paused;
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
