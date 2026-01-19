import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../models/agent_task.dart';
import '../models/context_node.dart';
import '../models/generation_context.dart';
import '../models/mcp_endpoint.dart';
import '../models/model_config.dart';
import 'tools/note_tools.dart';
import 'tools/read_task_result_tool.dart';
import 'ai_service.dart';
import 'agentic_settings_service.dart';
import 'context_manager_service.dart';
import 'model_selector.dart';
import 'logger_service.dart';
import 'mcp_tool_integration_service.dart';
import 'mcp_service.dart';
import 'database_service.dart';
import 'prompts/ai_prompts.dart';
import '../utils/think_tag_utils.dart';

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

/// Checkpoint types where agent can be paused.
enum AgentCheckpoint {
  beforeLlmCall,
  afterLlmResponse,
  beforeToolCall,
  afterToolResult,
}

class AgentService extends ChangeNotifier {
  // State
  List<AgentTask> _tasks = [];
  Map<String, List<McpTool>> _externalTools = {};
  bool _isRunning = false;
  String? _currentThought;
  String? _finalAnswer;
  Map<String, dynamic>? _finalMetadata;
  ToolExecutor? _toolExecutor;

  // Pause/Resume/Stop state
  bool _isPaused = false;
  String? _boundConversationId;
  AgentCheckpoint? _currentCheckpoint;

  /// Whether the agent is currently paused.
  bool get isPaused => _isPaused;

  /// The conversation ID that this agent is bound to.
  String? get boundConversationId => _boundConversationId;

  /// The current checkpoint type (for UI display).
  AgentCheckpoint? get currentCheckpoint => _currentCheckpoint;

  /// Callback for external progress updates (e.g., background notifications).
  /// Called whenever agent status changes (current thought updates).
  void Function(String status)? onProgressUpdate;

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

  /// Optional model override for agent LLM calls.
  ModelConfig? _modelOverride;
  ModelConfig? get modelOverride => _modelOverride;

  /// Enabled native tool names. If null, all native tools are enabled.
  /// This is set from the activeTools map when generating a plan.
  Set<String>? _enabledNativeToolNames;
  set modelOverride(ModelConfig? value) {
    _modelOverride = value;
    notifyListeners();
  }

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

  /// Returns only the native tools that are currently enabled.
  /// If no native tools are explicitly enabled via activeTools, returns all.
  List<NativeTool> get enabledNativeTools {
    if (_enabledNativeToolNames == null) return _nativeTools;
    return _nativeTools
        .where((t) => _enabledNativeToolNames!.contains(t.name))
        .toList();
  }

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
    // Clear pause/resume state
    _isPaused = false;
    _boundConversationId = null;
    _currentCheckpoint = null;
    // Clear model override
    _modelOverride = null;
    // Clear enabled native tools filter
    _enabledNativeToolNames = null;
    notifyListeners();
  }

  /// Pauses agent execution at the next checkpoint.
  void pauseExecution() {
    if (_isRunning && !_isPaused) {
      _isPaused = true;
      _currentThought = 'Pausing at next checkpoint...';

      // Mark current in-progress task as manually paused if possible
      // This helps UI distinguish between user pause and system pause (max turns)
      for (final t in _tasks) {
        if (t.status == AgentTaskStatus.inProgress) {
          t.isManuallyPaused = true;
          break; // Only one task runs at a time
        }
      }

      notifyListeners();
    }
  }

  /// Resumes agent execution after being paused.
  void resumeExecution() {
    if (_isPaused) {
      _isPaused = false;
      _currentCheckpoint = null;
      notifyListeners();
      // Restart the execution loop
      executePlan();
    }
  }

  /// Stops agent execution and clears all state.
  void stopExecution() {
    clearState();
  }

  /// Binds this agent to a conversation.
  void bindToConversation(String conversationId) {
    if (_boundConversationId != null &&
        _boundConversationId != conversationId) {
      // Switched conversations - ensure we don't leak state
      clearState();
    }
    _boundConversationId = conversationId;
  }

  /// Checks if a new agent can be started for the given conversation.
  /// Returns true if no agent is running/paused OR if it's the same conversation.
  bool canStartNewAgent(String? conversationId) {
    // If we have no bound activity, we can start.
    // If we bind to a new ID while idle, it's fine (bindToConversation handles the clear).
    if (!_isRunning && !_isPaused && _tasks.isEmpty) {
      return true;
    }

    // If current bound ID is null (shouldn't happen if running), we can start.
    if (_boundConversationId == null) {
      return true;
    }

    // If incoming conversation ID is null, we can't verify safety.
    if (conversationId == null) {
      return false;
    }

    // Same conversation - can start/continue
    if (conversationId == _boundConversationId) {
      return true;
    }

    // Different conversation while agent running/paused - cannot start
    return false;
  }

  /// Aborts the currently running task (for switching conversations).
  void abortCurrentTask() {
    stopExecution(); // This clears state and resets everything
  }

  // ... (nativeTools and dbSchema definitions remain the same) ...

  /// Mockable LLM generator for testing.
  /// If provided, this is used instead of AIService.generateWithAttachments.
  Future<String> Function(String prompt)? llmGenerator;

  /// Exposes _performTask for testing purposes.
  @visibleForTesting
  Future<void> performTaskForTest(AgentTask task, String globalContext) async {
    return _performTask(task, globalContext);
  }

  /// Helper to generate LLM response using either the mock or real service.
  Future<String> _generateLlmResponse(
    String prompt, {
    required GenerationContext context,
  }) async {
    if (llmGenerator != null) {
      return llmGenerator!(prompt);
    }
    return AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: context,
    );
  }

  /// ExecuteLoop with Hierarchical Context Management
  Future<void> _executeLoop() async {
    // Ensure root context exists (should be created in generatePlan)
    if (_contextManager.rootContext == null && _currentObjective != null) {
      await _contextManager.createRootContext(
        objective: _currentObjective!,
        allowedTools: getAllToolNames(),
      );
    }

    final rootContext = _contextManager.rootContext;

    // Build name-to-task map for dependency lookup
    final nameToTask = <String, AgentTask>{};
    for (final t in _tasks) {
      if (t.name != null) {
        nameToTask[t.name!] = t;
      }
    }

    while (_isRunning &&
        _tasks.any(
          (t) =>
              t.status == AgentTaskStatus.pending ||
              t.status == AgentTaskStatus.waitingForSubtasks ||
              t.status == AgentTaskStatus.paused,
        )) {
      // Find a task whose dependencies are all met
      final task = _tasks.cast<AgentTask?>().firstWhere((t) {
        if (t == null) return false;
        // Tasks waiting for subtasks need special handling
        if (t.status == AgentTaskStatus.waitingForSubtasks) {
          // Check if all spawned subtasks are completed
          final allSubtasksCompleted = t.spawnedSubtaskIds.every((subtaskId) {
            final subtask = _tasks.where((s) => s.id == subtaskId).firstOrNull;
            return subtask == null ||
                subtask.status == AgentTaskStatus.completed;
          });
          if (allSubtasksCompleted) {
            // Append subtask results to parent's execution history
            for (final subtaskId in t.spawnedSubtaskIds) {
              final subtask = _tasks
                  .where((s) => s.id == subtaskId)
                  .firstOrNull;
              if (subtask != null &&
                  subtask.status == AgentTaskStatus.completed) {
                t.executionHistory.add(
                  'Subtask "${subtask.description}" result: ${subtask.condensedSummary ?? subtask.result ?? "completed"}',
                );
              }
            }
            // Resume parent task - set back to inProgress
            t.status = AgentTaskStatus.inProgress;
            return true;
          }
          return false; // Still waiting for subtasks
        }
        if (t.status != AgentTaskStatus.pending &&
            t.status != AgentTaskStatus.paused) {
          return false;
        }
        // Check if all dependencies are completed
        for (final depName in t.dependsOn) {
          final depTask = nameToTask[depName];
          if (depTask == null) {
            // CRITICAL: Dependency missing! Do not run this task.
            // This prevents "pre-requisite task results missing" errors from LLM.
            LoggerService.error(
              'Task "${t.description}" depends on missing task "$depName". Skipping.',
            );
            return false;
          }
          if (depTask.status != AgentTaskStatus.completed) {
            return false; // Dependency not yet complete
          }
        }
        return true;
      }, orElse: () => null);

      // No runnable task found - might be circular dependency or all blocked
      if (task == null) {
        LoggerService.error(
          'No runnable task found - all pending tasks have unmet dependencies',
        );
        _currentThought = 'Error: No runnable task found (dependency issue)';
        _isRunning = false;
        notifyListeners();
        return;
      }

      // Create or get context node for this task
      ContextNode taskContext;
      if (task.contextNodeId != null) {
        taskContext =
            _contextManager.getContext(task.contextNodeId!) ??
            await _createTaskContext(task, rootContext);
      } else {
        taskContext = await _createTaskContext(task, rootContext);
        task.contextNodeId = taskContext.id;
      }

      _contextManager.setActiveContext(taskContext);

      // Update status
      task.status = AgentTaskStatus.inProgress;
      taskContext.status = ContextNodeStatus.active;
      _currentThought = 'Working on: ${task.description}';
      onProgressUpdate?.call(_currentThought!);
      notifyListeners();

      try {
        // Run ReAct loop for this task until it's done or paused
        while (task.status == AgentTaskStatus.inProgress && _isRunning) {
          // Check and compact context if nearing token limit
          await _contextManager.checkAndCompact(taskContext);

          // Build scoped context for this task
          // - Final deliverable tasks get synthesis context with accumulated findings
          // - Dynamically spawned subtasks get isolated context (briefing already in log)
          // - Planner-created research tasks get focused context (no redundant objectives)
          final String scopedContext;
          if (task.isFinalDeliverable) {
            scopedContext = _contextManager.buildSynthesisContext(taskContext);
          } else if (task.isSpawnedDynamically) {
            scopedContext = _contextManager.buildContextForSubtask(taskContext);
          } else {
            // Planner-created research task - collect structured dependency info
            final structuredDeps = <DependencyInfo>[];
            for (final depName in task.dependsOn) {
              final depTask = _tasks
                  .where((t) => t.name == depName)
                  .firstOrNull;
              if (depTask != null &&
                  depTask.status == AgentTaskStatus.completed) {
                final content =
                    depTask.condensedSummary ?? depTask.result ?? 'Completed';

                // Check if corresponding context node has structured result
                final depContext = depTask.contextNodeId != null
                    ? _contextManager.getContext(depTask.contextNodeId!)
                    : null;

                String toc = '';
                bool isShort = true;

                if (depContext?.structuredResult != null) {
                  final sr = depContext!.structuredResult!;
                  toc = sr.toc;
                  isShort = sr.isShortSync();
                } else {
                  // Fallback: estimate based on word count
                  final wordCount = content.split(RegExp(r'\s+')).length;
                  isShort = wordCount < 1000;
                  toc =
                      'No structured TOC available. Content: $wordCount words. Use read_task_result(task_id="${depTask.id}", mode="full") to read.';
                }

                structuredDeps.add(
                  DependencyInfo(
                    taskId: depTask.id,
                    name: depName,
                    content: content,
                    toc: toc,
                    isShort: isShort,
                  ),
                );
              }
            }
            scopedContext = _contextManager.buildContextForResearchTask(
              taskContext,
              structuredDependencies: structuredDeps,
            );
          }

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
        // If task is still inProgress but !_isRunning, mark it as paused for proper resumption.
        if (!_isRunning && task.status == AgentTaskStatus.inProgress) {
          task.status = AgentTaskStatus.paused;
          taskContext.status = ContextNodeStatus.paused;
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
              // Find tasks that depend on this task (consuming tasks)
              final consumingTaskDescriptions = <String>[];
              if (task.name != null) {
                for (final t in _tasks) {
                  if (t.dependsOn.contains(task.name)) {
                    consumingTaskDescriptions.add(t.description);
                  }
                }
              }

              task.condensedSummary = await _contextManager
                  .generateFinalSummary(
                    taskContext,
                    consumingTaskDescriptions: consumingTaskDescriptions,
                  );
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
  Future<ContextNode> _createTaskContext(
    AgentTask task,
    ContextNode? rootContext,
  ) async {
    if (rootContext == null) {
      return await _contextManager.createRootContext(
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

## Formatting Requirements
- Structure with proper markdown (headers, lists, code blocks, emphasis)
- When including math formulas, use LaTeX:
  - Inline: \\( formula \\) (e.g., \\( E = mc^2 \\))
  - Display: \\[ formula \\] (e.g., \\[ \\int_{0}^{\\infty} e^{-x^2} dx \\])

When referring to notes or conversations, use inline markdown links with the synapseresource:// URI scheme:
- For notes: [Note Title](synapseresource://note/<note_id>)
- For conversations: [Conversation Title](synapseresource://conversation/<conversation_id>)

Respond directly to: "$objective"
''';

    final genContext = GenerationContext(values: {'type': 'agent_summary'});
    if (_modelOverride != null) genContext.modelOverride = _modelOverride;
    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: genContext,
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
  Future<List<Map<String, dynamic>>> _extractStructuredFindings(
    AgentTask task,
  ) async {
    // Load configurable settings
    final findingLimit = await AgenticSettingsService.getFindingLimit();
    final maxWords = await AgenticSettingsService.getFindingMaxWords();

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

TASK EXECUTION CONTENT (observations, analysis, and reasoning):
$sourceContent

## EXTRACTION RULES

1. Extract ONLY verifiable facts with clear sources
2. Each finding MUST have:
   - finding: A specific data point, statistic, or claim (1-2 sentences, max $maxWords words)
   - source: The organization or publication name (e.g., "CDC", "USDA", "NSF 2024")
   - url: The actual URL if mentioned in the observations, otherwise use empty string ""
   - artifacts: An array of structured data objects associated with this finding. Each artifact must have:
     - type: "bulletpoint", "text", "code", or "image"
     - content: The actual content. For "image", this MUST be a URI (e.g., synapseresource://... or https://...), NOT base64.
   - (The total word count for finding + artifacts should be around $maxWords words)

3. CRITICAL: URLs are present in the observations - extract them accurately
4. Do NOT use placeholders like "Not specified" or "Unspecified" for URLs
5. If no URL is available, use empty string: "url": ""
6. Maximum $findingLimit findings per task
7. Use artifacts to preserve rich data like code snippets, detailed lists, or resource URIs.

## OUTPUT FORMAT

Return ONLY valid JSON array:
[
  {
    "finding": "Specific finding with numbers",
    "source": "Organization Name",
    "url": "https://...",
    "artifacts": [
      {"type": "bulletpoint", "content": "Supporting detail 1"},
      {"type": "code", "content": "print('hello world')"},
      {"type": "image", "content": "synapseresource://note/123/attachment/1.png"}
    ]
  }
]

If no findings worth preserving, return: []
''';

    final genContext = GenerationContext(
      values: {'type': 'extract_findings', 'taskId': task.id},
    );
    if (_modelOverride != null) genContext.modelOverride = _modelOverride;
    final response = await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: genContext,
    );

    return _parseFindings(response);
  }

  /// Extracts raw observation content from task execution history.
  /// Returns list of observation strings (tool outputs, analysis, answers, thoughts)
  /// before LLM summarization.
  List<String> _getRawObservations(AgentTask task) {
    final observations = <String>[];
    for (final entry in task.executionHistory) {
      // Capture tool observation outputs
      if (entry.startsWith('Observation:')) {
        observations.add(entry.substring('Observation:'.length).trim());
      }
      // Capture analysis from "think" actions - these contain valuable reasoning
      else if (entry.startsWith('Analysis:')) {
        observations.add(entry.substring('Analysis:'.length).trim());
      }
      // Capture answer content - the primary output of generative tasks
      else if (entry.startsWith('Answer:')) {
        observations.add(entry.substring('Answer:'.length).trim());
      }
      // Capture substantive thoughts (skip short/generic ones)
      else if (entry.startsWith('Thought:')) {
        final thought = entry.substring('Thought:'.length).trim();
        // Only include thoughts with substantial content (> 50 chars)
        if (thought.length > 50) {
          observations.add(thought);
        }
      }
    }
    return observations;
  }

  /// Parses findings JSON from LLM response.
  /// Normalizes URL values to remove placeholders like "Not specified".
  /// Includes details as a list of bullet points.
  List<Map<String, dynamic>> _parseFindings(String response) {
    try {
      final cleanResponse = extractJsonFromResponse(
        response,
        expectArray: true,
      );
      if (cleanResponse == null) return [];

      final List<dynamic> jsonList = jsonDecode(cleanResponse);
      return jsonList.map((item) {
        final map = item as Map<String, dynamic>;

        // Normalize URL: remove placeholders, keep only actual URLs
        String url = (map['url'] ?? '').toString().trim();
        if (_isPlaceholderUrl(url)) {
          url = '';
        }

        // Parse artifacts
        List<Map<String, String>> artifacts = [];
        if (map['artifacts'] != null && map['artifacts'] is List) {
          for (final a in map['artifacts']) {
            if (a is Map) {
              artifacts.add({
                'type': (a['type'] ?? 'text').toString(),
                'content': (a['content'] ?? '').toString(),
              });
            }
          }
        } else if (map['details'] != null && map['details'] is List) {
          // Backward compatibility for old "details" field
          artifacts = (map['details'] as List)
              .map(
                (d) => {'type': 'bulletpoint', 'content': d.toString().trim()},
              )
              .toList();
        }

        return <String, dynamic>{
          'finding': (map['finding'] ?? map['fact'] ?? '').toString().trim(),
          'source': (map['source'] ?? '').toString().trim(),
          'url': url,
          'artifacts': artifacts,
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
    CreateNotesTool(),
    DeleteNoteTool(),
  ];

  /// Cached ReadTaskResultTool instance (requires contextManager)
  ReadTaskResultTool? _readTaskResultTool;

  /// Gets all native tools including the read_task_result tool.
  List<NativeTool> get nativeTools {
    _readTaskResultTool ??= ReadTaskResultTool(_contextManager);
    return List.unmodifiable([..._nativeTools, _readTaskResultTool!]);
  }

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
    final names = enabledNativeTools.map((t) => t.name).toList();
    for (final entry in _externalTools.entries) {
      // Skip 'System' as it's already included via enabledNativeTools
      if (entry.key == 'System') continue;
      names.addAll(entry.value.map((t) => t.name));
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

    // Extract enabled native tool names from activeTools.
    // Native tools are passed under the 'System' key if explicitly selected.
    // If the 'System' key is not present or empty, all native tools are disabled
    // (unless no activeTools at all, in which case all are enabled for backwards compatibility).
    if (activeTools.isEmpty) {
      // No external tools configured at all - enable all native tools (legacy behavior)
      _enabledNativeToolNames = null;
    } else {
      final systemTools = activeTools['System'];
      if (systemTools != null && systemTools.isNotEmpty) {
        _enabledNativeToolNames = systemTools.map((t) => t.name).toSet();
      } else {
        // 'System' key not present or empty - no native tools enabled
        _enabledNativeToolNames = {};
      }
    }

    // Store objective and initialize root context for hierarchical management
    _currentObjective = objective;
    _contextManager.clear();
    await _contextManager.createRootContext(
      objective: objective,
      allowedTools: getAllToolNames(),
    );
    _contextManager.rootContext?.log('Planning phase started');
    if (context != null) {
      _contextManager.rootContext?.log('Additional context provided: $context');
    }

    notifyListeners();

    // Build descriptions for external tools if available
    // Build descriptions for external tools (excluding 'System' which is handled separately)
    String externalToolsDesc = '';
    if (_externalTools.isNotEmpty) {
      externalToolsDesc = '\nExternal Tools:\n';
      for (final entry in _externalTools.entries) {
        // Skip 'System' as native tools are handled separately
        if (entry.key == 'System') continue;
        externalToolsDesc += 'Service: ${entry.key}\n';
        for (final tool in entry.value) {
          externalToolsDesc +=
              '- ${tool.name}: ${tool.description}\n  Args: ${tool.inputSchema}\n';
        }
      }
    }

    // Use enabledNativeTools instead of _nativeTools to respect tool config
    final nativeToolsDesc = enabledNativeTools
        .map(
          (t) =>
              '- ${t.name}: ${t.description}\n  Args: ${t.inputSchema['properties']}',
        )
        .join('\n');

    final contextSection = context != null
        ? "\nAdditional Context:\n$context\n"
        : "";

    // Conditionally include Note Exploration guidance only when note tools are enabled
    final noteToolNames = {'search_notes', 'read_note', 'ls', 'run_sql'};
    final hasNoteTools = enabledNativeTools.any(
      (t) => noteToolNames.contains(t.name),
    );
    final noteExplorationSection = hasNoteTools
        ? '''

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
'''
        : '';

    final prompt =
        '''
You are an intelligent agent that plans and executes tasks to solve an objective.

Objective: "$objective"
$contextSection
Available Tools:
$nativeToolsDesc
$externalToolsDesc
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
$noteExplorationSection

## TASK CONFIGURATION

For each task, you MUST specify:
- "name": Short unique identifier (lowercase with underscores, e.g., "research_1918_social")
- "description": Human-readable task description
- "tools": List of tools to use (use [] if no tools needed)

Optional fields:
- "dependsOn": [names] - List of task names this task depends on. These tasks must complete first.
- "isFinalDeliverable": true for the task producing user's final answer (only one task)
- "extractFindings": true if this task's detailed results should be preserved for synthesis

## DEPENDENCY RULES

1. Tasks that synthesize, analyze, or hypothesize MUST depend on the research tasks they need
2. Every task name must be unique
3. No circular dependencies (A depends on B, B depends on A)
4. The isFinalDeliverable task should depend on all tasks it needs to synthesize
5. Tasks with no dependencies can run immediately

## OUTPUT FORMAT

Return ONLY valid JSON:
[
  {
    "name": "task_name",
    "description": "Step description",
    "tools": ["tool_name"],
    "dependsOn": ["prior_task_name"],
    "isFinalDeliverable": false,
    "extractFindings": true
  }
]

Example (research + synthesis):
[
  {"name": "research_topic_a", "description": "Research topic A with web search", "tools": ["brave_web_search"], "extractFindings": true},
  {"name": "research_topic_b", "description": "Research topic B with web search", "tools": ["brave_web_search"], "extractFindings": true},
  {"name": "synthesize", "description": "Synthesize findings into comprehensive report", "tools": [], "dependsOn": ["research_topic_a", "research_topic_b"], "isFinalDeliverable": true}
]

Example (note exploration):
[
  {"name": "explore_structure", "description": "Explore note structure with SQL", "tools": ["run_sql"], "extractFindings": true},
  {"name": "search_notes", "description": "Search for relevant notes", "tools": ["search_notes"], "extractFindings": true},
  {"name": "synthesize", "description": "Synthesize comprehensive report", "tools": [], "dependsOn": ["explore_structure", "search_notes"], "isFinalDeliverable": true}
];

If no tools are needed for a step (e.g. analysis), use: "tools": [].
Only use the tools listed above.
''';

    const maxRetries = 3;
    String? lastError;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        // Build prompt with error feedback if retrying
        final retryFeedback = lastError != null
            ? '''

## PREVIOUS PLAN ERROR
Your last plan had this issue: $lastError
Please fix and regenerate the plan.
'''
            : '';

        final fullPrompt = prompt + retryFeedback;

        final genContext = GenerationContext(values: {'type': 'agent_plan'});
        if (_modelOverride != null) genContext.modelOverride = _modelOverride;
        final response = await AIService.generateWithAttachments(
          fullPrompt,
          contextAttachments,
          generationContext: genContext,
        );

        // Load configurable max turns
        final defaultMaxTurns = await AgenticSettingsService.getMaxTurns();

        final List<AgentTask> tasks = _parseTasksFromJson(
          response,
          activeTools: getAllToolNames(),
          defaultMaxTurns: defaultMaxTurns,
        );

        // Validate dependency graph
        final validationError = _validatePlanDependencies(tasks);
        if (validationError != null) {
          lastError = validationError;
          LoggerService.warning(
            'Plan validation failed (attempt ${attempt + 1}): $validationError',
          );
          continue; // Retry
        }

        _tasks = tasks;
        _currentThought = 'Plan generated. Waiting for review.';
        notifyListeners();
        return _tasks;
      } catch (e) {
        lastError = e.toString();
        LoggerService.error(
          'Failed to generate plan (attempt ${attempt + 1}): $e',
        );
      }
    }

    // All retries failed - use fallback
    LoggerService.error(
      'All plan generation attempts failed. Last error: $lastError',
    );
    _tasks = [
      AgentTask(
        id: const Uuid().v4(),
        description: objective,
        name: 'main_task',
        status: AgentTaskStatus.pending,
      ),
    ];
    notifyListeners();
    return _tasks;
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

    final prompt =
        '''
Current Plan:
$currentPlanJson

General User Feedback:
$feedback
Update the plan based on the feedback.
Address specific feedback for items if present.
Return ONLY a valid JSON list of objects: [{"description": "...", "tools": ["..."]}]
''';

    try {
      final genContext = GenerationContext(
        values: {'type': 'agent_revise_plan'},
      );
      if (_modelOverride != null) genContext.modelOverride = _modelOverride;
      final response = await AIService.generateWithAttachments(
        prompt,
        [],
        generationContext: genContext,
      );

      final tasks = _parseTasksFromJson(
        response,
        activeTools: [
          ...enabledNativeTools.map((t) => t.name),
          ..._externalTools.entries
              .where((e) => e.key != 'System')
              .expand((e) => e.value.map((t) => t.name)),
        ],
        defaultMaxTurns: await AgenticSettingsService.getMaxTurns(),
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
    onProgressUpdate?.call(_currentThought!);
    notifyListeners();

    try {
      await _executeLoop();
    } catch (e) {
      LoggerService.error('Agent execution failure: $e');
      _currentThought = 'Error during execution: $e';
      onProgressUpdate?.call(_currentThought!);
    } finally {
      _isRunning = false;
      onProgressUpdate?.call('Agent completed');
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
  void resumeTask(String taskId, {bool increaseLimit = false}) async {
    // Ensure we unpause the agent globally so execution loop proceeds
    _isPaused = false;
    _currentCheckpoint = null;

    final task = _tasks.firstWhere((t) => t.id == taskId);
    if (increaseLimit) {
      final increment = await AgenticSettingsService.getTurnIncrement();
      task.maxTurns += increment;
    }

    notifyListeners();
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
    int? defaultMaxTurns,
  }) {
    try {
      final cleanResponse = extractJsonFromResponse(
        response,
        expectArray: true,
      );
      if (cleanResponse == null) {
        throw "No valid JSON task list found";
      }

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

        // Extract name (short unique identifier for dependency references)
        final name = map['name'] as String?;

        // Extract dependsOn list (names of tasks this depends on)
        List<String> dependsOn = [];
        if (map['dependsOn'] != null && map['dependsOn'] is List) {
          dependsOn = (map['dependsOn'] as List)
              .map((e) => e.toString())
              .toList();
        }

        return AgentTask(
          id: const Uuid().v4(),
          description: map['description'] ?? "No description",
          name: name,
          dependsOn: dependsOn,
          toolNames: tools,
          allowedTools: activeTools,
          isFinalDeliverable: isFinalDeliverable,
          extractFindings: extractFindings,
          maxTurns: defaultMaxTurns ?? 10,
        );
      }).toList();
    } catch (e) {
      LoggerService.error('Failed to parse JSON list: $e');
      rethrow;
    }
  }

  /// Validates the dependency graph for the plan.
  /// Returns error message if invalid, null if valid.
  String? _validatePlanDependencies(List<AgentTask> tasks) {
    // Build name-to-task map
    final nameToTask = <String, AgentTask>{};
    for (final task in tasks) {
      if (task.name != null) {
        if (nameToTask.containsKey(task.name)) {
          return 'Duplicate task name: ${task.name}';
        }
        nameToTask[task.name!] = task;
      }
    }

    // Check all dependsOn references are valid
    for (final task in tasks) {
      for (final dep in task.dependsOn) {
        if (!nameToTask.containsKey(dep)) {
          return 'Task "${task.name ?? task.description}" depends on unknown task: $dep';
        }
      }
    }

    // Check for cycles using DFS
    final visited = <String>{};
    final inStack = <String>{};

    bool hasCycle(String? name) {
      if (name == null) return false;
      if (inStack.contains(name)) return true;
      if (visited.contains(name)) return false;

      visited.add(name);
      inStack.add(name);

      final task = nameToTask[name];
      if (task != null) {
        for (final dep in task.dependsOn) {
          if (hasCycle(dep)) return true;
        }
      }

      inStack.remove(name);
      return false;
    }

    for (final task in tasks) {
      if (task.name != null && hasCycle(task.name)) {
        return 'Circular dependency detected involving: ${task.name}';
      }
    }

    // Check all tasks are reachable from isFinalDeliverable (walk backwards)
    final finalTask = tasks.where((t) => t.isFinalDeliverable).firstOrNull;
    if (finalTask != null && finalTask.name != null) {
      final reachable = <String>{};

      void walkDeps(String? name) {
        if (name == null || reachable.contains(name)) return;
        reachable.add(name);
        final task = nameToTask[name];
        if (task != null) {
          for (final dep in task.dependsOn) {
            walkDeps(dep);
          }
        }
      }

      walkDeps(finalTask.name);

      // Check for islands - tasks with names that aren't reachable
      for (final task in tasks) {
        if (task.name != null &&
            !reachable.contains(task.name) &&
            task.name != finalTask.name) {
          return 'Task "${task.name}" is not reachable from the final deliverable';
        }
      }
    }

    return null; // Valid
  }

  Future<void> _performTask(AgentTask task, String globalContext) async {
    // Check for max turns
    if (task.executionHistory.length / 2 >= task.maxTurns) {
      task.status = AgentTaskStatus.paused;
      task.result = "Max turns reached. Paused.";
      notifyListeners();
      return;
    }

    // If no tools AND not a final deliverable AND not extracting findings,
    // it's a pure no-op task. Skip LLM invocation.
    // BUT: tasks with extractFindings=true need LLM to generate content
    // even without external tools (e.g., creative writing, analysis).
    if (task.toolNames.isEmpty &&
        !task.isFinalDeliverable &&
        !task.extractFindings) {
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

    // Tool availability priority:
    // 1. task.allowedTools (user's explicit per-step restrictions via UI) - RESPECTED
    // 2. If empty, use all enabled tools
    // Note: task.toolNames (planner's suggestions) are hints only, not filters
    List<NativeTool> allowedNativeFn() {
      // read_task_result is ALWAYS available (internal mechanism for TOC-based context)
      // Use nativeTools (not enabledNativeTools) to ensure it's always present
      final readTaskResultTool = nativeTools
          .where((t) => t.name == 'read_task_result')
          .toList();

      // User's per-step restrictions take priority
      if (task.allowedTools.isNotEmpty) {
        final userFiltered = enabledNativeTools
            .where((t) => task.allowedTools.contains(t.name))
            .toList();
        // Ensure read_task_result is always included
        if (!userFiltered.any((t) => t.name == 'read_task_result')) {
          return [...userFiltered, ...readTaskResultTool];
        }
        return userFiltered;
      }
      // No user restriction - all enabled tools available + read_task_result
      if (!enabledNativeTools.any((t) => t.name == 'read_task_result')) {
        return [...enabledNativeTools, ...readTaskResultTool];
      }
      return enabledNativeTools;
    }

    List<McpTool> allowedExternalFn() {
      final all = _externalTools.values.expand((x) => x).toList();
      // User's per-step restrictions take priority
      if (task.allowedTools.isNotEmpty) {
        return all.where((t) => task.allowedTools.contains(t.name)).toList();
      }
      // No user restriction - all external tools available
      return all;
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
- If you have all the information you need, provide the complete, detailed output the user requested (report, analysis, etc.).
- You can provide your final result as a JSON action: ```json { "answer": "Full result here..." } ``` OR just write the result directly in Markdown.
- If you still need more information to fulfill the specific request of this task, you MUST use tool calls in JSON format.
- Do NOT provide a generic summary - give the full, detailed deliverable requested.
- Include all relevant data, citations, and findings from the context above.

${AIPrompts.agenticDeliverableGuidelines}
'''
        : '';

    // Use different format instructions based on whether this is a final deliverable
    final formatInstructions = task.isFinalDeliverable
        ? '''
FORMAT:
1. "My thought: [your reasoning about what's missing or how to structure the result]"
2. ONE action:
   - Use JSON format if you need a tool: ```json { "tool": "tool_name", "args": { ... } } ```
   - Use JSON format to finalize: ```json { "answer": "..." } ```
   - OR just write your complete Markdown result directly (fallback).
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
```json
{ "spawn_subtasks": [ { "description": "Subtask 1", "tools": ["tool1"] }, { "description": "Subtask 2", "tools": ["tool2"] } ] }
```
OR
```json
{ "answer": "Your complete task output" }
```

ACTION GUIDANCE:
- **think**: Analyze/reason about data ALREADY in execution history - don't reload files
- **tool**: Fetch NEW data not yet in context
- **spawn_subtasks**: Delegate complex work by spawning 1-5 focused subtasks at once (max depth: $kMaxSubtaskDepth)
  Use when: task needs parallel investigation, can be decomposed into independent parts, or benefits from context isolation
  Each subtask runs with isolated context but inherits parent findings
- **answer**: Provide your COMPLETE task output. For creative/generative tasks (write, create, expand),
  output the FULL content. For research tasks, output structured findings. The system will
  transform this appropriately for consuming tasks.

Current task depth: ${task.depth} / $kMaxSubtaskDepth
''';

    final prompt =
        '''
You are an intelligent agent working on a task.
Task Description: "${task.description}"

Global Context (includes current task execution log in <ExecutionLog> section):
$globalContext

Available Tools (read_task_result is always available for fetching context):
$toolsDesc

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
2. ONE action in JSON format (tool, think, spawn_subtasks, or answer)

This format is shown to the user to help them understand your reasoning.

INSTRUCTIONS:
1. Analyze the context and history.
2. Formulate a CLEAR THOUGHT about what to do next.
3. Choose ONE action:
   - "tool": Execute a tool to fetch NEW data
   - "think": Analyze data ALREADY in context (don't reload)
   - "spawn_subtasks": Decompose complex work into 1-5 focused child tasks
   - "answer": Complete the task when objective is satisfied
$deliverableInstructions
$formatInstructions
''';

    try {
      // Checkpoint: Before LLM call
      _currentCheckpoint = AgentCheckpoint.beforeLlmCall;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused before LLM call';
        notifyListeners();
        return;
      }

      final genContext = GenerationContext(
        values: {'type': 'agent_step', 'taskId': task.id, 'turn': turn},
      );
      if (_modelOverride != null) genContext.modelOverride = _modelOverride;
      final response = await _generateLlmResponse(prompt, context: genContext);

      // Checkpoint: After LLM response
      _currentCheckpoint = AgentCheckpoint.afterLlmResponse;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused after LLM response';
        task.executionHistory.add('Turn $turn: (paused after LLM response)');
        notifyListeners();
        return;
      }

      // ... Parsing Logic (Similar to before but inside this function) ...
      // Re-using existing ReAct parsing logic but ensuring it matches new flow

      // Strip <think> tags from response before parsing
      final thinkResult = stripThinkTags(response);
      final processedResponse = thinkResult.cleanedContent;

      // Preserve think content in execution history for context
      if (thinkResult.thinkContent != null &&
          thinkResult.thinkContent!.isNotEmpty) {
        task.executionHistory.add(
          'Model reasoning: ${thinkResult.thinkContent}',
        );
        _contextManager
            .getContext(task.contextNodeId ?? '')
            ?.log(
              'Model reasoning captured (${thinkResult.thinkContent!.length} chars)',
            );
      }

      // Use robust JSON extraction
      String? jsonStr = extractJsonFromResponse(processedResponse);
      String thought = '';

      Map<String, dynamic>? decision;

      if (jsonStr != null) {
        // Try parsing first to handle malformed recovery
        try {
          decision = jsonDecode(jsonStr) as Map<String, dynamic>;
        } catch (e) {
          // Robustness: If JSON fails (e.g. literal newlines), try regex extraction for 'answer'
          final answerMatch = RegExp(
            r'"answer"\s*:\s*"((?:[^"\\]|\\.)*)"',
            multiLine: true,
            dotAll: true,
          ).firstMatch(jsonStr);

          if (answerMatch != null) {
            final recoveredContent = answerMatch.group(1)!;
            decision = {'answer': recoveredContent};
            // Note: We keep jsonStr non-null so we proceed with "valid" decision.
          } else if (looksLikeAgentAction(jsonStr)) {
            // It has intent, but is malformed and unrecoverable. Trigger verdict/fallback.
            jsonStr = null;
            decision = null;
          }
        }

        if (jsonStr != null) {
          // Try to find where the JSON started to extract the thought
          final idx = processedResponse.indexOf(jsonStr);
          if (idx > 0) {
            thought = processedResponse.substring(0, idx).trim();
            // Strip trailing JSON fence markers (```json, ```)
            thought = thought
                .replaceAll(RegExp(r'```json\s*$', multiLine: true), '')
                .replaceAll(RegExp(r'```\s*$', multiLine: true), '')
                .trim();
          }

          // VALIDATION:
          // If this is a final deliverable, we must be careful not to mistake
          // code snippets or data in the report as an agent action.
          if (task.isFinalDeliverable) {
            if (decision != null) {
              if (!isAgentAction(decision)) {
                // It's JSON, but not an action. likely part of the report.
                jsonStr = null;
                decision = null;
                thought = '';
              }
            } else {
              // Malformed JSON and no intent detected. Treat as text.
              jsonStr = null;
            }
          }
        }
      }

      if (thought.startsWith('My thought:')) {
        thought = thought.replaceFirst('My thought:', '').trim();
      }
      _currentThought = thought.isNotEmpty ? thought : "Executing...";
      onProgressUpdate?.call(_currentThought!);
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
        // SPECIAL HANDLING: If no JSON found but it's a final deliverable,
        // treat the entire response as the answer (backward compatibility)
        if (task.isFinalDeliverable) {
          // Strip any "My thought:" prefix if present from CLEANED content
          String result = processedResponse.trim();
          final thoughtPrefix = RegExp(r'^My thought:.*?\n\n', dotAll: true);
          result = result.replaceFirst(thoughtPrefix, '').trim();

          // Also handle "My thought: ... \nAction: ..." or similar mixed formats if needed
          final singleLineThoughtPrefix = RegExp(
            r'^My thought:.*?\n',
            dotAll: true,
          );
          if (result.startsWith('My thought:')) {
            result = result.replaceFirst(singleLineThoughtPrefix, '').trim();
          }

          task.result = result;
          task.status = AgentTaskStatus.completed;
          task.executionHistory.add('Turn $turn:');
          task.executionHistory.add('Final deliverable produced directly.');

          if (task.contextNodeId != null) {
            _contextManager
                .getContext(task.contextNodeId!)
                ?.log('Turn $turn - Final deliverable produced directly');
          }

          _currentThought = "Delivered final result.";
          notifyListeners();
          return;
        }

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
Properly extracted content from the JSON string.
</content>
''';

        try {
          final verdictGenContext = GenerationContext(
            values: {'type': 'agent_verdict', 'taskId': task.id},
          );
          if (_modelOverride != null) {
            verdictGenContext.modelOverride = _modelOverride;
          }
          final verdictResponse = await _generateLlmResponse(
            verdictPrompt,
            context: verdictGenContext,
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
              // Store full answer content for findings extraction and context propagation
              task.executionHistory.add('Answer: $content');
              _contextManager
                  .getContext(task.contextNodeId ?? '')
                  ?.log('Task Result: $content');
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

      Map<String, dynamic> validDecision;
      if (decision != null) {
        validDecision = decision!;
      } else {
        try {
          validDecision = jsonDecode(jsonStr) as Map<String, dynamic>;
        } catch (e) {
          task.executionHistory.add("Error: Invalid JSON: $e");
          return;
        }
      }

      if (validDecision.containsKey('answer')) {
        final answerContent = validDecision['answer'].toString();
        task.result = answerContent;
        task.status = AgentTaskStatus.completed;
        // Store full answer content for findings extraction and context propagation
        task.executionHistory.add('Answer: $answerContent');
        _contextManager
            .getContext(task.contextNodeId ?? '')
            ?.log('Task Result: $answerContent');
        notifyListeners();
        return;
      }

      // Handle "think" action - pure reasoning on existing context
      if (validDecision.containsKey('think')) {
        final thinkContent = validDecision['think'] as String?;
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

      // Handle "spawn_subtasks" action - delegate work to 1-5 child tasks
      if (validDecision.containsKey('spawn_subtasks')) {
        final subtasksList = validDecision['spawn_subtasks'] as List?;
        if (subtasksList != null && subtasksList.isNotEmpty) {
          await _handleSpawnSubtasks(
            task,
            subtasksList.cast<Map<String, dynamic>>(),
          );
          return; // Subtasks spawned, continue loop to wait for them
        }
      }

      final toolName = validDecision['tool'] as String?;
      final args = validDecision['args'] as Map<String, dynamic>? ?? {};

      if (toolName == null) {
        task.executionHistory.add("Error: Missing 'tool' or 'answer' key.");
        return;
      }

      // Checkpoint: Before tool call
      _currentCheckpoint = AgentCheckpoint.beforeToolCall;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused before tool call: $toolName';
        task.executionHistory.add(
          'Turn $turn: (paused before tool call: $toolName)',
        );
        notifyListeners();
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
        // Try Native - use allowedNativeFn to respect tool config AND ensure read_task_result is always available
        final nativeTool = allowedNativeFn().firstWhere(
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

      // Checkpoint: After tool result
      _currentCheckpoint = AgentCheckpoint.afterToolResult;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused after tool result';
        notifyListeners();
        return;
      }
    } catch (e) {
      LoggerService.error("Agent Loop Error: $e");
      task.executionHistory.add("Error: Internal Agent Loop Error: $e");
    }
  }

  /// Handles LLM request to spawn 1-5 subtasks dynamically.
  Future<void> _handleSpawnSubtasks(
    AgentTask parentTask,
    List<Map<String, dynamic>> specs,
  ) async {
    // 1. Validate subtask count (1-5)
    if (specs.isEmpty || specs.length > 5) {
      parentTask.executionHistory.add(
        'Cannot spawn subtasks: must provide 1-5 subtasks (got ${specs.length})',
      );
      _currentThought = 'Invalid subtask count: ${specs.length}';
      notifyListeners();
      return;
    }

    // 2. Validate depth limit
    if (parentTask.depth >= kMaxSubtaskDepth) {
      parentTask.executionHistory.add(
        'Cannot spawn subtasks: maximum depth ($kMaxSubtaskDepth) reached. Use "think" to analyze or use "tool" to carry out tasks in current context instead.',
      );
      _currentThought = 'Subtask depth limit reached';
      notifyListeners();
      return;
    }

    // 3. Get parent context for sharing with subtasks
    final parentContext = _contextManager.getContext(
      parentTask.contextNodeId ?? '',
    );

    // 4. Extract all subtask descriptions for sibling awareness
    final allDescriptions = specs
        .map((s) => s['description'] as String?)
        .where((d) => d != null && d.isNotEmpty)
        .cast<String>()
        .toList();

    // 5. Create all subtasks
    final createdSubtasks = <AgentTask>[];
    for (int i = 0; i < specs.length; i++) {
      final spec = specs[i];
      final description = spec['description'] as String?;
      final toolsList = spec['tools'] as List?;
      final tools = toolsList?.cast<String>() ?? <String>[];

      if (description == null || description.isEmpty) {
        parentTask.executionHistory.add(
          'Skipping subtask with missing description',
        );
        continue;
      }

      // Create subtask with parent linkage
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

      // Create context for subtask with tailored briefing
      if (parentContext != null) {
        final childContext = _contextManager.createChildContext(
          parent: parentContext,
          objective: description,
          allowedTools: subtask.allowedTools,
        );
        subtask.contextNodeId = childContext.id;

        // Generate per-subtask briefing with sibling awareness
        try {
          final briefing = await _compactContextForSubtask(
            parentContext,
            description,
            allDescriptions.where((d) => d != description).toList(),
          );
          childContext.log(briefing);
        } catch (e) {
          LoggerService.error('Failed to compact context for subtask: $e');
          // Fallback: at least inform about siblings
          final siblings = allDescriptions
              .where((d) => d != description)
              .map((d) => '  - $d')
              .join('\n');
          childContext.log(
            'Parent objective: ${parentContext.objective}\n'
            'Parallel subtasks (do not duplicate their work):\n$siblings',
          );
        }
      }

      // Track spawned subtask
      parentTask.spawnedSubtaskIds.add(subtask.id);
      createdSubtasks.add(subtask);
    }

    if (createdSubtasks.isEmpty) {
      parentTask.executionHistory.add(
        'No valid subtasks created from specifications',
      );
      return;
    }

    // 6. Insert all subtasks after parent (in reverse order to maintain order)
    final parentIndex = _tasks.indexOf(parentTask);
    for (int i = createdSubtasks.length - 1; i >= 0; i--) {
      _tasks.insert(parentIndex + 1, createdSubtasks[i]);
    }

    // 7. Log and notify
    final subtaskDescriptions = createdSubtasks
        .map((t) => '"${t.description}"')
        .join(', ');
    parentTask.executionHistory.add(
      'Spawned ${createdSubtasks.length} subtasks [depth=${parentTask.depth + 1}]: $subtaskDescriptions',
    );
    _currentThought =
        'Spawned ${createdSubtasks.length} subtasks for parallel investigation';
    // Set parent to wait for subtasks - this breaks the inner ReAct loop
    parentTask.status = AgentTaskStatus.waitingForSubtasks;
    notifyListeners();
  }

  /// Compacts parent context for a specific subtask.
  /// Creates a tailored briefing for the subtask's objective while
  /// informing it about parallel sibling tasks to prevent duplication.
  Future<String> _compactContextForSubtask(
    ContextNode parentContext,
    String subtaskObjective,
    List<String> siblingObjectives,
  ) async {
    final siblingsList = siblingObjectives.isEmpty
        ? 'None'
        : siblingObjectives.map((o) => '  - $o').join('\n');

    final prompt =
        '''
You are handing off work to a colleague who will handle this specific subtask:
"$subtaskObjective"

PARALLEL SIBLING TASKS (do NOT duplicate their work):
$siblingsList

Provide a CONCISE briefing (max 400 words) tailored to THIS subtask:
1. What has been discovered that's RELEVANT to "$subtaskObjective"
2. Key data/URLs/findings this specific subtask will need
3. What NOT to repeat (already tried approaches OR being handled by siblings)

Current execution log:
${parentContext.executionLog.join('\n')}

Write a focused briefing for this subtask:
''';

    final genContext = GenerationContext(values: {'type': 'subtask_briefing'});
    if (_modelOverride != null) genContext.modelOverride = _modelOverride;
    return await AIService.generateWithAttachments(
      prompt,
      [],
      generationContext: genContext,
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
