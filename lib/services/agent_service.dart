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
  final List<NativeTool> _nativeTools = [NoteSearchTool(), NoteReadTool()];

  // Dependencies
  // We might need context or provider to get MCP tools,
  // but for now let's start with Native Tools.

  Future<void> startObjective(String objective) async {
    if (_isRunning) {
      // For now, allow restarting or queueing?
      // Let's reset.
      _tasks.clear();
    }
    _isRunning = true;
    _currentThought = 'Planning...';
    notifyListeners();

    try {
      await _plan(objective);
      await _executeLoop();
    } catch (e) {
      LoggerService.error('Agent failure: $e');
      _currentThought = 'Error: $e';
    } finally {
      _isRunning = false;
      notifyListeners();
    }
  }

  void cancel() {
    _isRunning = false;
    notifyListeners();
  }

  Future<void> _plan(String objective) async {
    // Basic planning prompt
    final prompt =
        '''
You are an intelligent agent helpful assistant.
Objective: $objective

Break this objective down into a logical list of steps (tasks).
Return ONLY a valid JSON list of strings, where each string is a task description.
Example: ["Search for notes about X", "Summarize the findings", "Create a new note"]
''';

    // We can use AIService.generateWithAttachments (without attachments)
    // or expose a simpler geneate method.
    // generateWithAttachments calls _singleTurnRequest which is fine.

    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(values: {'type': 'agent_plan'}),
    );

    // Parse JSON
    try {
      final cleaned = response
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      final List<dynamic> jsonList = jsonDecode(cleaned);

      _tasks = jsonList
          .map(
            (desc) => AgentTask(
              id: const Uuid().v4(),
              description: desc.toString(),
              status: AgentTaskStatus.pending,
            ),
          )
          .toList();

      notifyListeners();
    } catch (e) {
      LoggerService.error('Failed to parse plan: $response\nError: $e');
      // Fallback: Single task
      _tasks = [
        AgentTask(
          id: const Uuid().v4(),
          description: objective, // Treat original objective as single task
          status: AgentTaskStatus.pending,
        ),
      ];
      notifyListeners();
    }
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
    // 1. Select Tool
    // We construct a prompt listing tools.
    // Ideally we use Function Calling API if available,
    // but here we might simulating it via prompt if the chosen Model doesn't support it strictly?
    // Reference `McpToolIntegrationService` suggests we have generalized tool calling?
    // `AIService` via `ModelSelector` -> `AIModel`.
    // `GeminiModel` supports function declarations.
    // But `AIService`'s `executePrompt` doesn't expose tools arg easily yet?
    // Checks `ModelSelector`. `generateFromPrompt` takes `PromptRequest`.
    // `PromptRequest` (in prompt_models.dart) might support tools.

    // For now, I'll use PROMPT-based tool selection (ReAct style)
    // because I can't easily change the core AI Model interface safely right now.
    // ReAct prompt:

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

Decide what to do.
If you need to use a tool, return valid JSON: {"tool": "tool_name", "args": {...}}
If you can answer without tools (or done), return valid JSON: {"answer": "..."}

Return ONLY the JSON.
''';

    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: GenerationContext(values: {'type': 'agent_act'}),
    );

    // Parse Response
    Map<String, dynamic> decision;
    try {
      final cleaned = response
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      decision = jsonDecode(cleaned);
    } catch (e) {
      // Assume it's an answer?
      task.result = response;
      return;
    }

    if (decision.containsKey('tool')) {
      final toolName = decision['tool'];
      final args = decision['args'] as Map<String, dynamic>;

      final tool = _nativeTools.firstWhere(
        (t) => t.name == toolName,
        orElse: () => throw Exception('Unknown tool: $toolName'),
      );

      _currentThought = 'Executing $toolName...';
      notifyListeners();

      final result = await tool.execute(args);

      // We could loop here (Task -> Tool -> Result -> Next Tool),
      // but for V1, let's assume one tool per sub-task or just complete it.
      // Or store result and finish task.
      task.result = jsonEncode(result);
    } else if (decision.containsKey('answer')) {
      task.result = decision['answer'];
    } else {
      task.result = response; // Fallback
    }
  }
}
