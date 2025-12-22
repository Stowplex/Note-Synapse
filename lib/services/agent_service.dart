import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/agent_task.dart';
import '../models/generation_context.dart';
import 'tools/note_tools.dart';
import 'ai_service.dart';
import 'logger_service.dart';

class AgentService extends ChangeNotifier {
  // State
  List<AgentTask> _tasks = [];
  bool _isRunning = false;
  String? _currentThought;

  List<AgentTask> get tasks => List.unmodifiable(_tasks);
  bool get isRunning => _isRunning;
  String? get currentThought => _currentThought;

  // Tools
  // Tools
  final List<NativeTool> _nativeTools = [
    NoteSearchTool(),
    NoteReadTool(),
    RunSqlTool(),
  ];

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
  Future<List<AgentTask>> generatePlan(String objective) async {
    _currentThought = 'Generating plan...';
    notifyListeners();

    final prompt =
        '''
You are an intelligent agent helpful assistant.
Objective: $objective

Context:
You have access to a local SQLite database with personal notes.
DB Schema:
$_dbSchema

Break this objective down into a logical list of steps (tasks).
For each step, predict which tool you would use.

Available Tools:
- NoteSearchTool: Searching for notes (supports query and optional tags).
- NoteReadTool: Reading note content.
- RunSqlTool: Running SQL queries on local DB.

Pro-Tips for Note Probing:
1. Start broad: Use RunSqlTool to count notes or list broad categories/tags if unsure.
   e.g. "SELECT count(*) FROM notes", "SELECT name FROM tags".
2. Use Search for content: "NoteSearchTool" is best for finding text matches.
3. Drill down: Once you have IDs, use "NoteReadTool" to get details.

Return ONLY a valid JSON list of objects.
Example: [{"description": "Check total number of notes", "tool": "RunSqlTool"}, {"description": "Search for notes about X", "tool": "NoteSearchTool"}]
''';

    try {
      final response = await AIService.generateWithAttachments(
        prompt,
        [],
        generationContext: GenerationContext(values: {'type': 'agent_plan'}),
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

  /// Legacy entry point for auto-execution
  Future<void> startObjective(String objective) async {
    if (_isRunning) {
      _tasks.clear();
    }
    _isRunning = true;
    notifyListeners();

    try {
      await generatePlan(objective);
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

  Future<void> _executeLoop() async {
    while (_isRunning &&
        _tasks.any((t) => t.status == AgentTaskStatus.pending)) {
      final task = _tasks.firstWhere(
        (t) => t.status == AgentTaskStatus.pending,
      );

      // Update status
      task.status = AgentTaskStatus.inProgress;
      _currentThought = 'Working on: ${task.description}';
      notifyListeners();

      try {
        await _performTask(task);
        task.status = AgentTaskStatus.completed;
      } catch (e) {
        task.status = AgentTaskStatus.failed;
        task.result = 'Error: $e';
      }
      notifyListeners();
    }

    if (_tasks.every((t) => t.status == AgentTaskStatus.completed)) {
      _currentThought = 'All tasks completed.';
    }
  }

  Future<void> _performTask(AgentTask task) async {
    // ReAct Loop (max 20 turns to prevent premature cutoff)
    int turn = 0;
    const maxTurns = 20;
    final List<String> history = [];

    while (turn < maxTurns) {
      turn++;

      // 1. Construct Prompt with History
      final toolsDesc = _nativeTools
          .map((t) {
            return '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}';
          })
          .join('\n');

      final prompt =
          '''
Current Task: ${task.description}

Available Tools:
$toolsDesc

DB Schema:
$_dbSchema

History (Previous Actions):
${history.isEmpty ? "None" : history.join('\n')}

Instructions:
1. If you have enough info, return {"answer": "..."}.
2. If you need more info (or previous tool failed), use a tool.
3. If using RunSqlTool, ensure columns exist in DB Schema (e.g. use note_tags for tags, NOT notes.tags).
4. Do NOT stop unless you have found the answer or completed the action.
5. If you are stuck, return {"answer": "I am stuck..."} to ask user for help.

Decide what to do.
Return valid JSON: {"tool": "tool_name", "args": {...}} OR {"answer": "..."}
''';

      final response = await AIService.generateWithAttachments(
        prompt,
        [],
        generationContext: GenerationContext(values: {'type': 'agent_act'}),
      );

      // Parse Response
      Map<String, dynamic> decision;
      try {
        final jsonMatch = RegExp(r'\{.*\}', dotAll: true).firstMatch(response);
        final jsonStr = jsonMatch?.group(0) ?? response;
        final cleaned = jsonStr
            .replaceAll('```json', '')
            .replaceAll('```', '')
            .trim();
        decision = jsonDecode(cleaned);
      } catch (e) {
        // If parsing fails, it might be a malformed tool call.
        history.add('System: Invalid JSON format. Return ONLY JSON.');
        continue;
      }

      if (decision.containsKey('tool')) {
        final toolName = decision['tool'];
        final args = decision['args'] as Map<String, dynamic>;

        try {
          final tool = _nativeTools.firstWhere(
            (t) => t.name == toolName,
            orElse: () => throw Exception('Unknown tool: $toolName'),
          );

          _currentThought = 'Executing $toolName (Turn $turn)...';
          notifyListeners();

          final result = await tool.execute(args);
          final resultStr = jsonEncode(result);

          // Add to history
          history.add('Action: $toolName');
          history.add('Params: $args');

          // Truncate result if too long to save context
          final truncatedResult = resultStr.length > 2000
              ? '${resultStr.substring(0, 2000)}... (truncated)'
              : resultStr;
          history.add('Observation: $truncatedResult');

          // Loop continues...
        } catch (e) {
          history.add('Action: $toolName');
          history.add('Error: $e');
        }
      } else if (decision.containsKey('answer')) {
        task.result = decision['answer'];
        // Explicitly only mark completed if we got an answer
        return;
      } else {
        history.add('System: Invalid JSON. Must contain "tool" or "answer".');
      }
    }

    // If we exit loop without "answer", it's a failure (or stuck).
    task.result =
        'Error: Max execution turns ($maxTurns) reached without final answer.';
    task.status = AgentTaskStatus.failed;
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
