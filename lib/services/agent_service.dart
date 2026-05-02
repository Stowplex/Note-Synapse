import 'dart:async';
import 'dart:convert';

import 'package:json_repair_flutter/json_repair_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../models/agent_task.dart';
import '../models/context_node.dart';
import '../models/generation_context.dart';
import '../models/mcp_endpoint.dart';
import '../models/model_config.dart';
import '../models/model_type.dart';
import '../models/note.dart';
import 'tag_workflow_service.dart';
import 'tools/load_skill_tool.dart';
import 'tools/note_tools.dart';
import 'tools/read_task_result_tool.dart';
import 'ai_service.dart';
import 'agentic_settings_service.dart';
import 'context_manager_service.dart';
import 'model_selector.dart';
import 'logger_service.dart';
import 'ai_tool_service.dart';
import 'mcp_service.dart';
import 'skill_service.dart';
import 'user_app_service.dart';
import '../utils/xml_response_parser.dart';
import 'mcp_tool_integration_service.dart';
import 'prompts/prompt_models.dart';
import 'database_service.dart';
import 'service_locator.dart';

import 'prompts/ai_prompts.dart';
import '../utils/think_tag_utils.dart';
import '../utils/token_estimator.dart';

/// Callback for executing an external tool (MCP or local AI tool).
typedef ToolExecutor =
    Future<String> Function(
      String serviceName,
      String toolName,
      Map<String, dynamic> parameters,
      GenerationContext generationContext,
    );

/// Maximum allowed subtask depth (0=root, so 3 means 4 levels total)
/// @deprecated Use AgenticSettingsService.getMaxSubtaskDepth() instead.
/// This constant is kept for backward compatibility in tests.
const int kMaxSubtaskDepth = 2;

/// Checkpoint types where agent can be paused.
enum AgentCheckpoint {
  beforeLlmCall,
  afterLlmResponse,
  beforeToolCall,
  afterToolResult,
}

enum WorkflowExecutionState {
  running,
  pausedTurnLimit,
  pausedManual,
  completed,
  failed,
}

const String _systemToolServiceName = 'System';

class _RecoveredToolCall {
  final String serviceName;
  final String toolName;
  final Map<String, dynamic> params;

  const _RecoveredToolCall({
    required this.serviceName,
    required this.toolName,
    required this.params,
  });
}

class _ResolvedSkillTool {
  final String serviceName;
  final McpTool tool;

  const _ResolvedSkillTool({required this.serviceName, required this.tool});
}

class WorkflowStatusSnapshot {
  final String noteId;
  final String matchedTag;
  final String taskId;
  final WorkflowExecutionState state;
  final String message;
  final String noteTitle;
  final int turnsUsed;
  final int maxTurns;

  const WorkflowStatusSnapshot({
    required this.noteId,
    required this.matchedTag,
    required this.taskId,
    required this.state,
    required this.message,
    this.noteTitle = '',
    this.turnsUsed = 0,
    this.maxTurns = 0,
  });

  bool get isTerminal =>
      state == WorkflowExecutionState.completed ||
      state == WorkflowExecutionState.failed;

  bool get isPaused =>
      state == WorkflowExecutionState.pausedTurnLimit ||
      state == WorkflowExecutionState.pausedManual;

  WorkflowStatusSnapshot copyWith({
    WorkflowExecutionState? state,
    String? message,
    int? turnsUsed,
    int? maxTurns,
  }) {
    return WorkflowStatusSnapshot(
      noteId: noteId,
      matchedTag: matchedTag,
      taskId: taskId,
      state: state ?? this.state,
      message: message ?? this.message,
      noteTitle: noteTitle,
      turnsUsed: turnsUsed ?? this.turnsUsed,
      maxTurns: maxTurns ?? this.maxTurns,
    );
  }
}

/// Read-only snapshot of a queued workflow for UI display.
class PendingWorkflowInfo {
  final String noteId;
  final String noteTitle;
  final String matchedTag;
  const PendingWorkflowInfo({
    required this.noteId,
    required this.noteTitle,
    required this.matchedTag,
  });
}

class AgentService extends ChangeNotifier {
  final ContextManagerService _contextManager;
  final ModelSelector _modelSelector;
  final AIService _aiService;
  final DatabaseService _databaseService;

  AgentService(
    this._contextManager,
    this._modelSelector,
    this._aiService,
    this._databaseService,
  );

  // State
  List<AgentTask> _tasks = [];
  Map<String, List<McpTool>> _externalTools = {};
  bool _isRunning = false;
  String? _currentThought;
  String? _finalAnswer;
  Map<String, dynamic>? _finalMetadata;
  ToolExecutor? _toolExecutor;

  /// Cached max subtask depth from settings (loaded at execution start).
  int _cachedMaxSubtaskDepth = kMaxSubtaskDepth;

  // Workflow queue (for tag-triggered workflows)
  final List<_PendingWorkflow> _pendingWorkflows = [];
  WorkflowStatusSnapshot? _activeWorkflowStatus;

  /// Number of workflows queued waiting for the agent to become free.
  int get pendingWorkflowCount => _pendingWorkflows.length;
  WorkflowStatusSnapshot? get activeWorkflowStatus => _activeWorkflowStatus;

  /// Returns a snapshot of the pending workflow queue.
  List<PendingWorkflowInfo> get pendingWorkflows => _pendingWorkflows
      .map(
        (pw) => PendingWorkflowInfo(
          noteId: pw.note.id,
          noteTitle: pw.note.title,
          matchedTag: pw.binding.matchedTag,
        ),
      )
      .toList();

  /// Cancels a pending workflow by index. No-op if index is out of range.
  void cancelPendingWorkflow(int index) {
    if (index < 0 || index >= _pendingWorkflows.length) return;
    _pendingWorkflows.removeAt(index);
    notifyListeners();
  }

  WorkflowStatusSnapshot? workflowStatusForNote(String noteId) {
    final status = _activeWorkflowStatus;
    if (status == null || status.noteId != noteId) return null;
    return status;
  }

  /// Returns a short reference if the skill was pinned, or the full content if not.
  static String shortenSkillObservation({
    required String skillContent,
    required String skillName,
    required bool pinned,
  }) {
    if (!pinned) return skillContent;
    return "Skill '$skillName' loaded and pinned to context. "
        'See <LoadedSkills> section above for full instructions.';
  }

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
    // Reset cached settings
    _cachedMaxSubtaskDepth = kMaxSubtaskDepth;
    // Clear workflow queue
    _pendingWorkflows.clear();
    _activeWorkflowStatus = null;
    _skillDiscoveredTools.clear();
    _skillToolServiceNames.clear();

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
  Future<void> resumeExecution() async {
    if (_isPaused) {
      _isPaused = false;
      _currentCheckpoint = null;
      notifyListeners();
      // Restart the execution loop
      await executePlan();
    }
  }

  /// Stops agent execution and clears all state.
  void stopExecution() {
    clearState();
    _modelSelector.dispose();
  }

  /// Binds this agent to a conversation.
  void bindToConversation(String conversationId) {
    if (_boundConversationId != null &&
        _boundConversationId != conversationId) {
      // Switched conversations - ensure we don't leak state
      clearState();
      _modelSelector.dispose();
    }
    _boundConversationId = conversationId;
  }

  /// Checks if a new agent can be started for the given conversation.
  /// Returns true if no agent is running/paused OR if it's the same conversation.
  bool canStartNewAgent(String? conversationId) {
    // If incoming conversation ID is null, we can't verify safety.
    if (conversationId == null) {
      return false;
    }

    // If we have no bound activity, we can start.
    // If we bind to a new ID while idle, it's fine (bindToConversation handles the clear).
    if (!_isRunning && !_isPaused && _tasks.isEmpty) {
      return true;
    }

    // If current bound ID is null (shouldn't happen if running), we can start.
    if (_boundConversationId == null) {
      return true;
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

  /// Exposes _performTask for testing purposes.
  @visibleForTesting
  Future<void> performTaskForTest(AgentTask task, String globalContext) async {
    return _performTask(task, globalContext);
  }

  @visibleForTesting
  set toolExecutor(ToolExecutor? executor) => _toolExecutor = executor;

  @visibleForTesting
  set externalToolsForTest(Map<String, List<McpTool>> tools) =>
      _externalTools = tools;

  /// Helper to generate LLM response using either the mock or real service.
  Future<String> _generateLlmResponse(
    String prompt, {
    required GenerationContext context,
  }) async {
    return await _aiService.generateWithAttachments(
      prompt,
      [],
      generationContext: context,
    );
  }

  /// Whether the effective model should use native function calling instead of
  /// XML-based tool actions. Currently gated to local models (Gemma) only.
  bool _useNativeFunctionCalling() {
    final config = _modelOverride ?? _modelSelector.currentModelConfig;
    if (config == null) return false;
    return config.type == ModelType.localMnn;
  }

  /// Generate a response using native function declarations (for models that
  /// support tool calling). Returns the raw model response map containing
  /// `text`, `function_calls`, and `modelUsed`.
  Future<Map<String, dynamic>> _generateLlmResponseWithTools(
    String systemPrompt,
    String userPrompt,
    Map<String, List<McpTool>> toolsByService, {
    required GenerationContext context,
  }) async {
    final tools = _modelSelector.buildToolDeclarations(
      toolsByService,
      generationContext: context,
    );
    final messages = [
      PromptMessage(role: PromptRole.system, content: systemPrompt),
      PromptMessage(role: PromptRole.user, content: userPrompt),
    ];
    return await _modelSelector.generateWithToolsAndMessages(
      messages,
      tools,
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
        // Get configurable TOC inline threshold for this task execution
        final tocThreshold =
            await AgenticSettingsService.getTocInlineThreshold();

        // Run ReAct loop for this task until it's done or paused
        while (task.status == AgentTaskStatus.inProgress && _isRunning) {
          // Check and compact context if nearing token limit
          await _contextManager.checkAndCompact(taskContext);

          // Build scoped context for this task
          // - Final deliverable tasks get synthesis context with accumulated findings AND dependencies
          // - Dynamically spawned subtasks get isolated context (briefing already in log)
          // - Planner-created research tasks get focused context (no redundant objectives)
          final String scopedContext;

          // Collect structured dependencies for use in context
          final structuredDeps = _collectDependencyInfo(task, tocThreshold);

          if (task.isFinalDeliverable) {
            scopedContext = _contextManager.buildSynthesisContext(
              taskContext,
              structuredDependencies: structuredDeps,
            );
          } else if (task.isSpawnedDynamically) {
            scopedContext = _contextManager.buildContextForSubtask(taskContext);
          } else {
            // Planner-created research task - use collected structured dependency info
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

          // Clear previous error state AFTER it has been rendered into the context
          taskContext.lastError = null;

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
                  .where((s) => s.id == subtaskId)
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
                    modelOverride: _modelOverride,
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
          _finalAnswer = deliverableTask.result!;
          _finalMetadata = {
            'modelUsed': _modelSelector.currentModelConfig?.id,
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

    final db = _databaseService;
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

  /// Collects structured dependency info for a task.
  List<DependencyInfo> _collectDependencyInfo(
    AgentTask task,
    int tocThreshold,
  ) {
    final structuredDeps = <DependencyInfo>[];
    for (final depName in task.dependsOn) {
      final depTask = _tasks.where((t) => t.name == depName).firstOrNull;
      if (depTask != null && depTask.status == AgentTaskStatus.completed) {
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
          isShort = sr.isShortSync(threshold: tocThreshold);
        } else {
          // Fallback: estimate based on token count
          final tokenCount = TokenEstimator.estimateTokens(content);
          isShort = tokenCount < tocThreshold;
          // Use contextNodeId for read_task_result lookups
          final lookupId = depTask.contextNodeId ?? depTask.id;
          toc =
              'No structured TOC available. Content: $tokenCount tokens. Use read_task_result(task_id="$lookupId", mode="full") to read.';
        }

        structuredDeps.add(
          DependencyInfo(
            taskId: depTask.contextNodeId ?? depTask.id,
            name: depName,
            content: content,
            toc: toc,
            isShort: isShort,
          ),
        );
      }
    }
    return structuredDeps;
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

When referring to notes, conversations, or attachments, use inline markdown links with the synapseresource:// URI scheme:
- For notes: [Note Title](synapseresource://note/<note_id>)
- For conversations: [Conversation Title](synapseresource://conversation/<conversation_id>)
- For attachments: [Label](synapseresource://attachment/<attachment_id>?page=<1-indexed page number>)
  The ?page= parameter is optional; when provided it opens the attachment at that page.

Respond directly to: "$objective"
''';

    final genContext = GenerationContext(values: {'type': 'agent_summary'});
    if (_modelOverride != null) genContext.modelOverride = _modelOverride;
    final response = await _generateLlmResponse(prompt, context: genContext);

    // Parse the response to extract content if it's in XML format
    String finalContent = response;
    try {
      final parsed = parseXmlAgentResponse(response);
      if (parsed.isValid) {
        if (parsed.actionType == 'answer' && parsed.content != null) {
          finalContent = parsed.content!;
        } else if (parsed.content != null) {
          // Fallback to content if other type
          finalContent = parsed.content!;
        }
      }
    } catch (e) {
      LoggerService.warning('Failed to parse final summary XML: $e');
    }

    _finalAnswer = finalContent;
    // Capture metadata for the UI
    _finalMetadata = {
      'modelUsed': _modelSelector.currentModelConfig?.id,
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
    final response = await _aiService.generateWithAttachments(
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

      // Try standard decode first, fall back to repairJson for malformed responses
      List<dynamic> jsonList;
      try {
        jsonList = jsonDecode(cleanResponse) as List<dynamic>;
      } catch (_) {
        final repaired = repairJson(cleanResponse);
        if (repaired is! List) return [];
        jsonList = repaired;
      }
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
    ModifyNotesTool(),
    CreateNotesTool(),
    DeleteNoteTool(),
  ];

  /// Cached ReadTaskResultTool instance (requires contextManager)
  ReadTaskResultTool? _readTaskResultTool;

  // Skill state
  bool _skillsEnabled = true;
  Map<String, SkillMetadata> _skillIndex = {};
  final List<McpTool> _skillDiscoveredTools = [];
  final Map<String, String> _skillToolServiceNames = {};
  LoadSkillTool? _loadSkillTool;

  /// Gets all native tools including the read_task_result tool.
  List<NativeTool> get nativeTools {
    _readTaskResultTool ??= ReadTaskResultTool(_contextManager);
    if (_skillsEnabled) {
      _loadSkillTool ??= LoadSkillTool();
      return List.unmodifiable([
        ..._nativeTools,
        _readTaskResultTool!,
        _loadSkillTool!,
      ]);
    }
    return List.unmodifiable([..._nativeTools, _readTaskResultTool!]);
  }

  Map<String, String> getToolToServiceMap() {
    final map = <String, String>{};
    for (final t in nativeTools) {
      map[t.name] = _systemToolServiceName;
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
    bool skillsEnabled = true,
  }) async {
    _externalTools = activeTools;
    _toolExecutor = executeTool;
    _skillsEnabled = skillsEnabled;
    _skillDiscoveredTools.clear();
    _skillToolServiceNames.clear();
    getIt<SkillService>().resetSession();
    _loadSkillTool?.resetSession();

    if (_skillsEnabled) {
      _skillIndex = await getIt<SkillService>().buildSkillIndex();
    } else {
      _skillIndex = {};
    }

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

    final skillIndexSection = () {
      if (!_skillsEnabled) return '';
      final index = getIt<SkillService>().buildSkillIndexPrompt(
        _skillIndex,
        forLocalModel: _useNativeFunctionCalling(),
      );
      final defaultAction =
          getIt<SkillService>().buildDefaultActionPromptSection(_skillIndex);
      if (defaultAction.isNotEmpty) {
        return '$index\n\n$defaultAction';
      }
      return index;
    }();

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
$skillIndexSection''';

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
        final response = await _aiService.generateWithAttachments(
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
              'name': t.name,
              'description': t.description,
              'tools': t.toolNames,
              'dependsOn': t.dependsOn,
              'isFinalDeliverable': t.isFinalDeliverable,
              'extractFindings': t.extractFindings,
              if (t.userComment != null && t.userComment!.isNotEmpty)
                'user_feedback': t.userComment,
            },
          )
          .toList(),
    );

    final prompt =
        '''
## CURRENT PLAN
$currentPlanJson

## USER FEEDBACK
$feedback

## INSTRUCTIONS
Update the plan based on the user feedback.
- Address specific item feedback (marked as "user_feedback" in the JSON above) if present.
- Preserve the dependency structure: tasks that synthesize or need results from other tasks MUST have those tasks in "dependsOn".
- Keep exactly ONE task with "isFinalDeliverable": true (the task producing the user's final answer).
- Mark research/exploration tasks with "extractFindings": true if their results should be preserved for synthesis.

## OUTPUT FORMAT
Return ONLY a valid JSON list with ALL required fields:
[
  {
    "name": "unique_task_name",
    "description": "Task description",
    "tools": ["tool_name"],
    "dependsOn": ["prior_task_name"],
    "isFinalDeliverable": false,
    "extractFindings": true
  },
  {
    "name": "final_synthesis",
    "description": "Synthesize and deliver final answer",
    "tools": [],
    "dependsOn": ["unique_task_name"],
    "isFinalDeliverable": true,
    "extractFindings": false
  }
]
''';

    try {
      final genContext = GenerationContext(
        values: {'type': 'agent_revise_plan'},
      );
      if (_modelOverride != null) genContext.modelOverride = _modelOverride;
      final response = await _aiService.generateWithAttachments(
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

    // Load max subtask depth from settings (cached for this execution)
    _cachedMaxSubtaskDepth = await AgenticSettingsService.getMaxSubtaskDepth();

    try {
      await _executeLoop();
    } catch (e) {
      LoggerService.error('Agent execution failure: $e');
      _currentThought = 'Error during execution: $e';
      onProgressUpdate?.call(_currentThought!);
    } finally {
      _isRunning = false;
      if (_activeWorkflowStatus == null) {
        onProgressUpdate?.call('Agent completed');
      }
      _syncWorkflowStatusFromTasks();
      _processWorkflowQueueIfReady();

      // Dispose models to free resources after workflow completes
      _modelSelector.dispose();

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
      // Dispose models to free resources after objective completes
      _modelSelector.dispose();
      notifyListeners();
    }
  }

  void cancel() {
    _isRunning = false;
    _currentThought = 'Cancelled by user.';
    notifyListeners();
  }

  /// Substitutes template variables in a workflow prompt.
  ///
  /// Replaces `{note_id}` with [noteId] and `{matched_tag}` with [matchedTag].
  static String substitutePromptTemplate(
    String template, {
    required String noteId,
    required String matchedTag,
  }) {
    return template
        .replaceAll('{note_id}', noteId)
        .replaceAll('{matched_tag}', matchedTag);
  }

  /// Short label for task.description and node.objective (~20 tokens).
  /// Repeated in ancestor goals, current task headers, and log entries.
  static String buildWorkflowLabel({
    required String prompt,
    required ResolvedBinding binding,
    required Note note,
  }) {
    final suffix = ' — "${note.title}" [${binding.matchedTag}]';
    const maxLength = 99;
    // Reserve 1 char for the ellipsis when truncating
    final maxPromptLength = maxLength - suffix.length - 1;
    final truncatedPrompt =
        maxPromptLength > 0 && prompt.length > maxPromptLength
        ? '${prompt.substring(0, maxPromptLength)}…'
        : prompt;
    return '$truncatedPrompt$suffix';
  }

  /// Full execution context with binding metadata (~400 tokens).
  /// Stored once on root.executionContext, emitted once per turn.
  static String buildWorkflowContext({
    required ResolvedBinding binding,
    required Note note,
  }) {
    final otherTags = note.tags
        .where((tag) => tag != binding.matchedTag)
        .toList();
    final otherTagsText = otherTags.isEmpty ? '(none)' : otherTags.join(', ');

    return '''
This workflow was triggered automatically by a tag-to-workflow binding.
- Source note ID: ${note.id}
- Source note title: ${note.title}
- Triggered tag on this note: ${binding.matchedTag}
- Binding pattern: ${binding.pattern}
- Other tags currently on the source note: $otherTagsText

The bound workflow skill has already been loaded into <LoadedSkills> for this run.
Use the source note above as "this note" for the workflow. Do not search for a candidate source note unless the workflow instructions explicitly require finding related notes beyond this source note.'''
        .trim();
  }

  /// Deprecated: use [buildWorkflowLabel] + [buildWorkflowContext] instead.
  @Deprecated('Use buildWorkflowLabel and buildWorkflowContext separately')
  static String buildWorkflowObjective({
    required String prompt,
    required ResolvedBinding binding,
    required Note note,
  }) {
    final label = buildWorkflowLabel(
      prompt: prompt,
      binding: binding,
      note: note,
    );
    final context = buildWorkflowContext(binding: binding, note: note);
    return '$label\n\nWorkflow execution context:\n$context';
  }

  List<String> _initialWorkflowAllowedTools() {
    final allowed = <String>['read_task_result'];
    if (_skillsEnabled &&
        nativeTools.any((tool) => tool.name == 'load_skill')) {
      allowed.add('load_skill');
    }
    return allowed;
  }

  AgentTaskValidationProfile _workflowValidationProfileForBinding(
    ResolvedBinding binding,
  ) {
    final normalizedPrompt = binding.prompt.toLowerCase();
    if (binding.matchedTag.startsWith('wiki-source-') ||
        normalizedPrompt.contains('wiki ingest')) {
      return AgentTaskValidationProfile.wikiIngest;
    }
    return AgentTaskValidationProfile.none;
  }

  Future<String?> _preloadBoundWorkflowSkill({
    required ResolvedBinding binding,
    required AgentTask task,
  }) async {
    if (!_skillsEnabled) {
      return null;
    }

    final loadSkillTool = nativeTools
        .where((tool) => tool.name == 'load_skill')
        .firstOrNull;
    if (loadSkillTool is! LoadSkillTool) {
      return 'Workflow setup failed: load_skill is unavailable.';
    }

    final result = await loadSkillTool.execute({'noteId': binding.skillNoteId});
    if (result is! String) {
      return 'Workflow setup failed: unable to load bound skill ${binding.skillNoteId}. '
          'Result: $result';
    }

    // Substitute <ns> placeholder with the actual namespace from the binding.
    // Skill notes use <ns> as a template variable (e.g., "wiki-source-<ns>").
    // For tag "wiki-source-ai-research" with pattern "wiki-source-", namespace
    // is "ai-research".
    var skillContent = result;
    if (binding.matchedTag.length > binding.pattern.length) {
      final namespace = binding.matchedTag.substring(binding.pattern.length);
      skillContent = skillContent.replaceAll('<ns>', namespace);
    }

    final pinned = await _handleLoadSkillResult(
      binding.skillNoteId,
      skillContent,
      task: task,
    );
    final observation = pinned
        ? shortenSkillObservation(
            skillContent: skillContent,
            skillName: _extractSkillName(skillContent),
            pinned: true,
          )
        : 'Skill already loaded: ${_extractSkillName(skillContent)}';

    task.executionHistory.add(
      'Bootstrap: preloaded bound workflow skill ${binding.skillNoteId}',
    );
    task.executionHistory.add('Observation: $observation');
    _contextManager.rootContext?.log(
      'Bootstrap: preloaded bound workflow skill ${binding.skillNoteId}',
    );
    _contextManager.rootContext?.log('Observation: $observation');
    return null;
  }

  void _promoteSkillDiscoveredTools(List<String> toolNames) {
    if (toolNames.isEmpty) return;

    for (final task in _tasks) {
      if (task.allowedTools.isEmpty) continue;
      for (final toolName in toolNames) {
        if (!task.allowedTools.contains(toolName)) {
          task.allowedTools.add(toolName);
        }
      }
    }

    final root = _contextManager.rootContext;
    if (root != null) {
      for (final toolName in toolNames) {
        if (!root.allowedTools.contains(toolName)) {
          root.allowedTools.add(toolName);
        }
      }
    }

    final current = _contextManager.currentContext;
    if (current != null) {
      for (final toolName in toolNames) {
        if (!current.allowedTools.contains(toolName)) {
          current.allowedTools.add(toolName);
        }
      }
    }
  }

  Map<String, List<McpTool>> _buildAgentToolsByService({
    required List<NativeTool> nativeTools,
    required List<McpTool> externalTools,
  }) {
    final grouped = <String, List<McpTool>>{};
    final seenToolNames = <String>{};

    if (nativeTools.isNotEmpty) {
      final nativeMcpTools = <McpTool>[];
      for (final tool in nativeTools) {
        if (seenToolNames.add(tool.name)) {
          nativeMcpTools.add(McpTool(
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema,
          ));
        }
      }
      if (nativeMcpTools.isNotEmpty) {
        grouped[_systemToolServiceName] = nativeMcpTools;
      }
    }

    for (final tool in externalTools) {
      if (!seenToolNames.add(tool.name)) continue;

      final serviceName = _skillToolServiceNames[tool.name] ??
          _externalTools.entries
              .where(
                (entry) =>
                    entry.value.any((candidate) => candidate.name == tool.name),
              )
              .map((entry) => entry.key)
              .firstOrNull;
      if (serviceName == null || serviceName.isEmpty) {
        continue;
      }
      grouped.putIfAbsent(serviceName, () => <McpTool>[]).add(tool);
    }

    return grouped;
  }

  _RecoveredToolCall? _recoverAgentToolCall(
    String requestedToolName,
    Map<String, dynamic> args, {
    required Map<String, List<McpTool>> toolsByService,
    String? fallbackSearchQuery,
  }) {
    Map<String, dynamic>? parsed;
    if (requestedToolName == 'call_tool') {
      parsed = McpToolIntegrationService.parseCallToolArguments(args);
    } else {
      // Handle optional prefixes like "System." or "Mcp." from local models
      final normalizedName = requestedToolName.contains('.')
          ? requestedToolName.split('.').last
          : requestedToolName;

      final directTool = _resolveUniqueToolByName(
        normalizedName,
        toolsByService,
      );
      if (directTool != null) {
        parsed = McpToolIntegrationService.parseCallToolArguments(
          args,
          fallbackServiceName: directTool['service_name'],
          fallbackToolName: directTool['tool_name'],
          logErrors: false,
        );
        parsed ??= {
          'service_name': directTool['service_name'],
          'tool_name': directTool['tool_name'],
          'params': Map<String, dynamic>.from(args),
        };
      }
    }

    if (parsed == null) {
      return null;
    }

    final toolName = parsed['tool_name'] as String;
    final params =
        (parsed['params'] as Map<String, dynamic>? ?? <String, dynamic>{});

    if (toolName == 'search_notes') {
      final query = (params['query'] as String? ?? '').trim();
      if (query.isEmpty &&
          fallbackSearchQuery != null &&
          fallbackSearchQuery.isNotEmpty) {
        params['query'] = fallbackSearchQuery;
      }
    }

    return _RecoveredToolCall(
      serviceName: parsed['service_name'] as String,
      toolName: toolName,
      params: params,
    );
  }

  Map<String, String>? _resolveUniqueToolByName(
    String toolName,
    Map<String, List<McpTool>> toolsByService,
  ) {
    final matches = <Map<String, String>>[];
    for (final entry in toolsByService.entries) {
      for (final tool in entry.value) {
        if (tool.name == toolName) {
          matches.add({'service_name': entry.key, 'tool_name': tool.name});
        }
      }
    }
    return matches.length == 1 ? matches.first : null;
  }

  Future<dynamic> _executeSystemTool({
    required String toolName,
    required Map<String, dynamic> args,
    required List<NativeTool> allowedNativeTools,
  }) async {
    final nativeTool = allowedNativeTools.firstWhere(
      (tool) => tool.name == toolName,
      orElse: () => _UnknownTool(),
    );
    if (nativeTool is! _UnknownTool) {
      return nativeTool.execute(args);
    }

    final skillDiscoveredBuiltin =
        _skillDiscoveredTools.any((tool) => tool.name == toolName)
        ? _nativeTools.firstWhere(
            (tool) => tool.name == toolName,
            orElse: () => _UnknownTool(),
          )
        : _UnknownTool();
    if (skillDiscoveredBuiltin is! _UnknownTool) {
      return skillDiscoveredBuiltin.execute(args);
    }

    throw 'Tool $toolName not found.';
  }

  Future<String> _resolveSkillNoteId(Map<String, dynamic> args) async {
    final noteId = (args['noteId'] as String? ?? '').trim();
    if (noteId.isNotEmpty) {
      return noteId;
    }

    final skillRef = (args['skillRef'] as String? ?? '').trim();
    if (skillRef.isEmpty) {
      return '';
    }

    final noteIdForRef = getIt<SkillService>().resolveNoteIdForSkillRef(
      _skillIndex,
      skillRef,
    );
    if (noteIdForRef != null && noteIdForRef.isNotEmpty) {
      return noteIdForRef;
    }

    final refreshedIndex = await getIt<SkillService>().buildSkillIndex();
    _skillIndex = refreshedIndex;
    return getIt<SkillService>().resolveNoteIdForSkillRef(
          refreshedIndex,
          skillRef,
        ) ??
        '';
  }

  String? _inferSearchQueryForTask(AgentTask task) {
    final lower = task.description.toLowerCase();
    final patterns = <RegExp>[
      RegExp(r'"([^"]+)"'),
      RegExp(r'what is ([^?]+)\??', caseSensitive: false),
      RegExp(r'who is ([^?]+)\??', caseSensitive: false),
      RegExp(r'about ([^.?]+)', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(task.description);
      final query = match?.group(1)?.trim();
      if (query != null && query.isNotEmpty && query.toLowerCase() != lower) {
        return query;
      }
    }
    return null;
  }

  /// Executes a tag-triggered workflow as a single [AgentTask].
  ///
  /// If the agent is already running, the workflow is queued and will be
  /// executed when the agent becomes free.
  Future<void> runWorkflowTask({
    required ResolvedBinding binding,
    required Note note,
  }) async {
    if (_isRunning) {
      _pendingWorkflows.add(_PendingWorkflow(binding, note));
      notifyListeners();
      return;
    }

    final substitutedPrompt = substitutePromptTemplate(
      binding.prompt,
      noteId: note.id,
      matchedTag: binding.matchedTag,
    );
    final workflowLabel = buildWorkflowLabel(
      prompt: substitutedPrompt,
      binding: binding,
      note: note,
    );
    final workflowContext = buildWorkflowContext(binding: binding, note: note);
    final workflowAllowedTools = _initialWorkflowAllowedTools();

    // Save pending workflows before clearing state
    final savedPendingWorkflows = List.of(_pendingWorkflows);

    // Clear all previous state
    clearState();

    // Restore pending workflows
    _pendingWorkflows.addAll(savedPendingWorkflows);

    _currentObjective = workflowLabel;
    final workflowMaxTurns = await AgenticSettingsService.getMaxTurns();
    final taskId = const Uuid().v4();
    _activeWorkflowStatus = WorkflowStatusSnapshot(
      noteId: note.id,
      matchedTag: binding.matchedTag,
      taskId: taskId,
      state: WorkflowExecutionState.running,
      message: 'Running workflow for "${binding.matchedTag}"',
      noteTitle: note.title,
      turnsUsed: 0,
      maxTurns: workflowMaxTurns,
    );

    // Create root context for the workflow
    await _contextManager.createRootContext(
      objective: workflowLabel,
      allowedTools: workflowAllowedTools,
    );
    _contextManager.rootContext?.executionContext = workflowContext;
    final task = AgentTask(
      id: taskId,
      description: workflowLabel,
      name: 'workflow_task',
      isFinalDeliverable: true,
      status: AgentTaskStatus.pending,
      allowedTools: workflowAllowedTools,
      maxTurns: workflowMaxTurns,
      validationProfile: _workflowValidationProfileForBinding(binding),
    );
    _tasks = [task];

    final preloadError = await _preloadBoundWorkflowSkill(
      binding: binding,
      task: task,
    );
    if (preloadError != null) {
      task.status = AgentTaskStatus.failed;
      task.result = preloadError;
      task.executionHistory.add('Observation: $preloadError');
      _contextManager.rootContext?.log('Observation: $preloadError');
      _currentThought = preloadError;
      _activeWorkflowStatus = _activeWorkflowStatus?.copyWith(
        state: WorkflowExecutionState.failed,
        message: preloadError,
      );
      _isRunning = false;
      notifyListeners();
      _processWorkflowQueueIfReady();
      return;
    }

    notifyListeners();

    _isRunning = true;
    _currentThought = 'Starting workflow: ${binding.matchedTag}';
    onProgressUpdate?.call(_currentThought!);
    notifyListeners();

    // Load cached max subtask depth from settings
    _cachedMaxSubtaskDepth = await AgenticSettingsService.getMaxSubtaskDepth();

    try {
      await _executeLoop();
    } catch (e) {
      LoggerService.error('Workflow execution failure: $e');
      _currentThought = 'Workflow error: $e';
      onProgressUpdate?.call(_currentThought!);
      _activeWorkflowStatus = _activeWorkflowStatus?.copyWith(
        state: WorkflowExecutionState.failed,
        message: 'Workflow failed: $e',
      );
    } finally {
      _isRunning = false;
      _syncWorkflowStatusFromTasks();
      if (_activeWorkflowStatus?.state == WorkflowExecutionState.completed) {
        onProgressUpdate?.call('Workflow completed');
      }
      if (_activeWorkflowStatus?.state == WorkflowExecutionState.failed) {
        onProgressUpdate?.call(_activeWorkflowStatus!.message);
      }

      // Dispose models to free resources after workflow completes
      _modelSelector.dispose();

      notifyListeners();
      _processWorkflowQueueIfReady();
    }
  }

  /// Processes the next pending workflow in the queue, if any.
  void _processWorkflowQueueIfReady() {
    final activeWorkflow = _activeWorkflowStatus;
    if (activeWorkflow != null && !activeWorkflow.isTerminal) {
      return;
    }
    if (_pendingWorkflows.isEmpty || _isRunning) return;
    final next = _pendingWorkflows.removeAt(0);
    // Fire and forget - errors logged inside runWorkflowTask
    runWorkflowTask(binding: next.binding, note: next.note);
  }

  // _performTask moved to end of file

  // Intervention Methods

  /// Resumes a paused task, optionally increasing its turn limit.
  Future<void> resumeTask(String taskId, {bool increaseLimit = false}) async {
    // Ensure we unpause the agent globally so execution loop proceeds
    _isPaused = false;
    _currentCheckpoint = null;

    final task = _tasks.firstWhere((t) => t.id == taskId);
    if (increaseLimit) {
      final increment = await AgenticSettingsService.getTurnIncrement();
      task.maxTurns += increment;
    }
    task.isManuallyPaused = false;
    if (_activeWorkflowStatus?.taskId == taskId) {
      _activeWorkflowStatus = _activeWorkflowStatus?.copyWith(
        state: WorkflowExecutionState.running,
        message: 'Resumed workflow for "${_activeWorkflowStatus!.matchedTag}"',
      );
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
    _syncWorkflowStatusFromTasks();
    notifyListeners();
    executePlan(); // Move to next task
  }

  /// Aborts a task (and effectively the plan for now).
  void abortTask(String taskId) {
    final task = _tasks.firstWhere((t) => t.id == taskId);
    task.status = AgentTaskStatus.failed;
    task.result = "Aborted by user.";
    _isRunning = false;
    _syncWorkflowStatusFromTasks();
    notifyListeners();
    _processWorkflowQueueIfReady();
  }

  int _countTaskTurns(AgentTask task) {
    return task.executionHistory
        .where((entry) => entry.startsWith('Turn '))
        .length;
  }

  bool _isTurnLimitPause(AgentTask task) {
    return task.status == AgentTaskStatus.paused &&
        !task.isManuallyPaused &&
        (task.result?.startsWith('Max turns reached.') ?? false);
  }

  void _syncWorkflowStatusFromTasks() {
    final workflow = _activeWorkflowStatus;
    if (workflow == null) return;

    final task = _tasks.where((t) => t.id == workflow.taskId).firstOrNull;
    if (task == null) {
      _activeWorkflowStatus = null;
      return;
    }

    if (task.status == AgentTaskStatus.completed) {
      _activeWorkflowStatus = workflow.copyWith(
        state: WorkflowExecutionState.completed,
        message: 'Workflow completed for "${workflow.matchedTag}"',
        turnsUsed: _countTaskTurns(task),
        maxTurns: task.maxTurns,
      );
      return;
    }

    if (task.status == AgentTaskStatus.failed) {
      _activeWorkflowStatus = workflow.copyWith(
        state: WorkflowExecutionState.failed,
        message: task.result ?? 'Workflow failed',
        turnsUsed: _countTaskTurns(task),
        maxTurns: task.maxTurns,
      );
      return;
    }

    if (task.status == AgentTaskStatus.paused) {
      _activeWorkflowStatus = workflow.copyWith(
        state: _isTurnLimitPause(task)
            ? WorkflowExecutionState.pausedTurnLimit
            : WorkflowExecutionState.pausedManual,
        message: task.result ?? 'Workflow paused',
        turnsUsed: _countTaskTurns(task),
        maxTurns: task.maxTurns,
      );
      return;
    }

    if (task.status == AgentTaskStatus.inProgress ||
        task.status == AgentTaskStatus.pending ||
        task.status == AgentTaskStatus.waitingForSubtasks) {
      _activeWorkflowStatus = workflow.copyWith(
        state: WorkflowExecutionState.running,
        message: 'Running workflow for "${workflow.matchedTag}"',
        turnsUsed: _countTaskTurns(task),
        maxTurns: task.maxTurns,
      );
    }
  }

  void _recordToolExecution(
    AgentTask task, {
    required String toolName,
    required Map<String, dynamic> args,
    required dynamic result,
    required bool succeeded,
  }) {
    task.toolExecutionRecords.add(
      AgentToolExecutionRecord(
        toolName: toolName,
        args: Map<String, dynamic>.from(args),
        result: result.toString(),
        succeeded: succeeded,
      ),
    );
  }

  String? _validateFinalAnswer(AgentTask task, String answerContent) {
    switch (task.validationProfile) {
      case AgentTaskValidationProfile.none:
        return null;
      case AgentTaskValidationProfile.wikiIngest:
        return _validateWikiIngestAnswer(task, answerContent);
    }
  }

  String? _validateWikiIngestAnswer(AgentTask task, String answerContent) {
    final normalized = answerContent.toLowerCase();
    final isPartial =
        normalized.contains('partial ingest') ||
        normalized.contains('partially ingested') ||
        normalized.contains('incomplete');
    if (isPartial) {
      return null;
    }

    bool hasSuccessfulExecution(String toolName) =>
        task.toolExecutionRecords.any(
          (record) =>
              record.succeeded &&
              (record.toolName == toolName ||
                  record.toolName.endsWith('.$toolName')),
        );

    final hasSuccessfulModify =
        hasSuccessfulExecution('modify_notes') ||
        hasSuccessfulExecution('modify_note');
    if (!hasSuccessfulModify) {
      return 'Cannot report wiki ingest completion yet. No successful modify_notes or modify_note observation was recorded for index/log/source updates.';
    }

    final claimsCreatedNotes =
        RegExp(r'\b(created?|creating)\b').hasMatch(normalized) ||
        normalized.contains('new entity') ||
        normalized.contains('new topic') ||
        normalized.contains('new compiled');
    if (claimsCreatedNotes && !hasSuccessfulExecution('create_notes')) {
      return 'Cannot claim created wiki notes without a successful create_notes observation.';
    }

    return null;
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

      // Try standard decode first, fall back to repairJson for malformed responses
      List<dynamic> jsonList;
      try {
        jsonList = jsonDecode(cleanResponse) as List<dynamic>;
      } catch (_) {
        final repaired = repairJson(cleanResponse);
        if (repaired is! List) {
          throw "JSON repair failed - not a list";
        }
        jsonList = repaired;
      }
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

  /// Updates the tool executor used by the agent.
  ///
  /// This is critical for handling lifecycle mismatches where the UI layer (Screen)
  /// is disposed and recreated (e.g. during model switch or navigation) while
  /// the AgentService remains running. The new UI must provide a fresh executor
  /// that references valid HeadlessInAppWebView instances.
  void updateToolExecutor(ToolExecutor executor) {
    _toolExecutor = executor;
    LoggerService.info('AgentService: ToolExecutor updated by UI');
  }

  Future<void> _performTask(AgentTask task, String globalContext) async {
    // Check for max turns
    final turnsUsed = _countTaskTurns(task);
    if (turnsUsed >= task.maxTurns) {
      task.status = AgentTaskStatus.paused;
      task.result = "Max turns reached. Paused.";
      task.isManuallyPaused = false;
      _syncWorkflowStatusFromTasks();
      notifyListeners();
      return;
    }

    // Sync workflow status for mini-player turn display
    _syncWorkflowStatusFromTasks();

    // NOTE: We no longer skip tasks with empty tools.
    // Tasks with tools: [] are valid "thinking" tasks where the LLM should:
    // - Analyze context and reason about the problem
    // - Produce creative output (stories, outlines, analysis)
    // - Synthesize information from dependencies
    // The LLM will use action type="answer" when it completes the task.

    final int turn = turnsUsed + 1;

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
      // read_task_result and load_skill (when skills enabled) are ALWAYS available
      // (internal mechanisms for TOC-based context and skill loading)
      // Use nativeTools (not enabledNativeTools) to ensure they're always present
      final alwaysAvailableNames = {
        'read_task_result',
        if (_skillsEnabled) 'load_skill',
      };
      final alwaysAvailableTools = nativeTools
          .where((t) => alwaysAvailableNames.contains(t.name))
          .toList();

      // User's per-step restrictions take priority
      if (task.allowedTools.isNotEmpty) {
        final userFiltered = enabledNativeTools
            .where((t) => task.allowedTools.contains(t.name))
            .toList();
        // Ensure always-available tools are included
        final missing = alwaysAvailableTools
            .where((t) => !userFiltered.any((u) => u.name == t.name))
            .toList();
        if (missing.isNotEmpty) {
          return [...userFiltered, ...missing];
        }
        return userFiltered;
      }
      // No user restriction - all enabled tools available + always-available tools
      final missing = alwaysAvailableTools
          .where((t) => !enabledNativeTools.any((u) => u.name == t.name))
          .toList();
      if (missing.isNotEmpty) {
        return [...enabledNativeTools, ...missing];
      }
      return enabledNativeTools;
    }

    List<McpTool> allowedExternalFn() {
      final all = [
        ..._externalTools.values.expand((x) => x),
        ..._skillDiscoveredTools,
      ];
      // Deduplicate by name to prevent list bloat/drift
      final seen = <String>{};
      final unique = all.where((t) => seen.add(t.name)).toList();

      // User's per-step restrictions take priority
      if (task.allowedTools.isNotEmpty) {
        return unique
            .where((t) => task.allowedTools.contains(t.name))
            .toList();
      }
      // No user restriction - all external tools available
      return unique;
    }

    final currentAllowedNative = allowedNativeFn();
    final currentAllowedExternal = allowedExternalFn();
    final toolsByService = _buildAgentToolsByService(
      nativeTools: currentAllowedNative,
      externalTools: currentAllowedExternal,
    );

    // Fallback: If for some reason the planned tool isn't found in native/external,
    // we should alert or fail? For now, we proceed with what we found.
    final toolsDesc = McpToolIntegrationService.buildMcpSystemPrompt(
      toolsByService,
      maxBudgetTokens: 16000,
    ).trim();

    // Build special instructions for final deliverable tasks
    final deliverableInstructions = task.isFinalDeliverable
        ? '''

IMPORTANT: This is the FINAL DELIVERABLE task.
- If you have all the information you need, provide the complete, detailed output the user requested (report, analysis, etc.).
- If you still need more information to fulfill the specific request of this task, you MUST use a tool call.
- Do NOT provide a generic summary - give the full, detailed deliverable requested.
- Include all relevant data, citations, and findings from the context above.

${AIPrompts.agenticDeliverableGuidelines}
'''
        : '';

    // Use different format instructions based on whether this is a final deliverable
    // Build a concrete service_name example from the available tools so
    // the model doesn't have to guess casing or naming conventions.
    final exampleServiceName = toolsByService.keys.isNotEmpty
        ? toolsByService.keys.first
        : _systemToolServiceName;
    final formatInstructions = task.isFinalDeliverable
        ? '''
RESPONSE FORMAT (XML-based):

Two action types are available. Pick ONE per turn.

1. TOOL CALL (to fetch data or execute an action):
<MyThought>why you need this tool</MyThought>
<Action type="tool">
<ToolName>call_tool</ToolName>
<Content>{"service_name":"$exampleServiceName", "tool_name":"TOOL_NAME", "params": {...}}</Content>
</Action>

2. FINAL ANSWER (when the task is complete — NO <ToolName> tag):
<MyThought>why you are done</MyThought>
<Action type="answer">
<Content>
Your markdown answer here.
</Content>
</Action>
'''
        : '''
RESPONSE FORMAT (XML-based for reliable parsing):

Structure your response as:
<MyThought>Your reasoning about what to do next</MyThought>
<Action type="ACTION_TYPE">
  <ToolName>call_tool</ToolName>
  <Content>action content</Content>
</Action>

ACTION TYPES AND CONTENT FORMAT:
- **tool**: Execute a tool. <ToolName> MUST be `call_tool`. Content MUST be a JSON object in this exact shape: {"service_name":"...", "tool_name":"...", "params": {...}}.
- **think**: Analyze data in context. Content is free-form text.
- **spawn_subtasks**: Decompose into 1-5 child tasks. Content MUST be a JSON array: [{"description": "...", "tools": [...]}]
- **answer**: Complete the task. Content is your markdown result. Do NOT include <ToolName>.

> For "tool" and "spawn_subtasks", Content must be valid JSON (no code fences).

EXAMPLES:

<Example>
<MyThought>I need to search for relevant notes.</MyThought>
<Action type="tool">
<ToolName>call_tool</ToolName>
<Content>{"service_name":"$_systemToolServiceName","tool_name":"search_notes","params":{"query":"machine learning"}}</Content>
</Action>
</Example>

<Example>
<MyThought>I have all the information needed.</MyThought>
<Action type="answer">
<Content>
# Analysis Report

## Summary
The investigation reveals that...

## Findings
1. First finding
2. Second finding
</Content>
</Action>
</Example>

<Example>
<MyThought>This task is complex and should be decomposed.</MyThought>
<Action type="spawn_subtasks">
<Content>[{"description": "Research topic A", "tools": ["search"]}, {"description": "Research topic B", "tools": ["search"]}]</Content>
</Action>
</Example>

<Example>
<MyThought>I need to analyze the data already in context.</MyThought>
<Action type="think">
<Content>Looking at the execution history, I notice patterns in the data...</Content>
</Action>
</Example>

Current task depth: ${task.depth} / $_cachedMaxSubtaskDepth
''';

    // Filter skill index to remove already loaded skills from the available list.
    // This prevents models from hallucinating redundant load_skill calls.
    final loadedNoteIds = _contextManager.rootContext?.loadedSkills
            .map((s) => s.noteId)
            .toSet() ??
        {};
    final filteredSkillIndex = Map<String, SkillMetadata>.from(_skillIndex)
      ..removeWhere((key, value) => loadedNoteIds.contains(value.noteId));

    final taskSkillSection = () {
      if (!_skillsEnabled || filteredSkillIndex.isEmpty) return '';
      final index = getIt<SkillService>().buildSkillIndexPrompt(
        filteredSkillIndex,
        maxBudgetTokens: 16000,
        forLocalModel: _useNativeFunctionCalling(),
      );
      final defaultAction = getIt<SkillService>()
          .buildDefaultActionPromptSection(filteredSkillIndex);
      if (defaultAction.isNotEmpty) {
        return '$index\n\n$defaultAction';
      }
      return index;
    }();

    final prompt =
        '''
You are an intelligent agent working on a task.
Task Description: "${task.description}"

Global Context (includes current task execution log in <ExecutionLog> section):
$globalContext

Available Tools:
$toolsDesc

## ITERATION PROTOCOL

After each action, evaluate:
1. Did I get what I needed? If yes, proceed to answer.
2. Are there gaps? Make another tool call OR spawn a subtask.
3. Is the problem complex? Consider spawning subtasks for focused investigation.

You may call tools MULTIPLE TIMES per task if needed.
Don't settle for incomplete information when tools are available.

INSTRUCTIONS:
1. Analyze the context and history.
2. Formulate a CLEAR THOUGHT about what to do next.
3. Choose ONE action:
   - "tool": Execute a tool to fetch NEW data
   - "think": Analyze data ALREADY in context
   - "spawn_subtasks": Decompose complex work into 1-5 focused child tasks
   - "answer": Complete the task when objective is satisfied
$deliverableInstructions

$formatInstructions
$taskSkillSection''';

    try {
      // Checkpoint: Before LLM call
      _currentCheckpoint = AgentCheckpoint.beforeLlmCall;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused before LLM call';
        _syncWorkflowStatusFromTasks();
        notifyListeners();
        return;
      }

      final genContext = GenerationContext(
        values: {'type': 'agent_step', 'taskId': task.id, 'turn': turn},
      );
      if (_modelOverride != null) genContext.modelOverride = _modelOverride;

      // Branch: native function calling for local models vs XML for others
      if (_useNativeFunctionCalling()) {
        await _performTaskNativeFunctionCalling(
          task: task,
          turn: turn,
          globalContext: globalContext,
          deliverableInstructions: deliverableInstructions,
          taskSkillSection: taskSkillSection,
          toolsByService: toolsByService,
          genContext: genContext,
          allowedNativeFn: allowedNativeFn,
          currentAllowedNative: currentAllowedNative,
          onProgressUpdate: onProgressUpdate,
        );
        return;
      }

      final response = await _generateLlmResponse(prompt, context: genContext);

      // Checkpoint: After LLM response
      _currentCheckpoint = AgentCheckpoint.afterLlmResponse;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused after LLM response';
        task.executionHistory.add('Turn $turn: (paused after LLM response)');
        _syncWorkflowStatusFromTasks();
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

      LoggerService.debug(
        '[Agent Parsing] Processed Response:\n$processedResponse',
      );

      // Use XML parser for response parsing
      final xmlResponse = parseXmlAgentResponse(processedResponse);
      LoggerService.debug('[Agent Parsing] XML Parse Result: $xmlResponse');

      // Extract thought from XML
      String thought = xmlResponse.thought ?? '';
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

      // Handle parsing errors
      if (xmlResponse.hasError) {
        // STRICT MODE: If an Action tag was present but malformed, report error
        // back to LLM for correction. This catches cases like:
        // - <Action type="tool"> without <ToolName>
        // - <Action type="tool"> without <Content>
        // - Invalid JSON in <Content>
        // These are structural errors that the LLM should fix.
        if (xmlResponse.isMalformedAction) {
          final errorMsg = xmlResponse.parseError!;
          _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
              'IMPORTANT: $errorMsg';
          task.executionHistory.add("Observation: $errorMsg");
          _contextManager
              .getContext(task.contextNodeId ?? '')
              ?.log('Observation: $errorMsg');
          notifyListeners();
          return;
        }

        // FALLBACK: If NO Action tag was found at all and it's a final deliverable,
        // treat the entire response as the answer (backward compatibility for
        // models that respond with plain text instead of XML structure).
        if (task.isFinalDeliverable) {
          // HEURISTIC CHECK FOR MALFORMED TOOL CALLS:
          // If the response looks like it tried to call a tool but failed parsing,
          // DO NOT treat it as a final answer. Reject it so the agent can fix it.
          final lowerResponse = processedResponse.toLowerCase();
          final hasToolTag =
              lowerResponse.contains('<tool>') ||
              lowerResponse.contains('<toolname>');
          final hasActionTag = lowerResponse.contains('<action');
          final hasTypeAttr =
              lowerResponse.contains('type="tool"') ||
              lowerResponse.contains("type='tool'");

          if (hasToolTag || (hasActionTag && hasTypeAttr)) {
            final baseError = xmlResponse.parseError ?? 'Unknown parse error.';
            final errorMsg =
                'Potential malformed tool call detected in final deliverable. The response contained tool-like tags but failed strict XML parsing. Error: $baseError';

            _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
                'IMPORTANT: $errorMsg. Please correct your XML syntax.';
            task.executionHistory.add("Observation: $errorMsg");
            notifyListeners();
            return;
          }

          // Strip any "My thought:" prefix if present from CLEANED content
          String result = processedResponse.trim();
          final thoughtPrefix = RegExp(r'^My thought:.*?\n\n', dotAll: true);
          result = result.replaceFirst(thoughtPrefix, '').trim();

          // Also handle "<MyThought>..." stripped format
          final xmlThoughtPrefix = RegExp(
            r'^<MyThought>.*?</MyThought>\s*',
            dotAll: true,
            caseSensitive: false,
          );
          result = result.replaceFirst(xmlThoughtPrefix, '').trim();

          // Strip common XML wrapper tags that LLMs might incorrectly use
          // These patterns handle the case where the LLM uses non-standard formats
          // like <answer>...</answer> instead of <Action type="answer"><Content>...

          // Strip <answer>...</answer> wrapper (incorrect format used by some LLMs)
          final answerWrapper = RegExp(
            r'^<answer>\s*(.*?)\s*</answer>\s*$',
            dotAll: true,
            caseSensitive: false,
          );
          final answerMatch = answerWrapper.firstMatch(result);
          if (answerMatch != null) {
            result = answerMatch.group(1)?.trim() ?? result;
          }

          // Strip <Action...>...<Content>...</Content>...</Action> wrapper
          final actionWrapper = RegExp(
            r'^<Action[^>]*>\s*(?:<Content>\s*)?(.*?)(?:\s*</Content>)?\s*</Action>\s*$',
            dotAll: true,
            caseSensitive: false,
          );
          final actionMatch = actionWrapper.firstMatch(result);
          if (actionMatch != null) {
            result = actionMatch.group(1)?.trim() ?? result;
          }

          final validationError = _validateFinalAnswer(task, result);
          if (validationError != null) {
            _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
                'IMPORTANT: $validationError';
            task.executionHistory.add('Observation: $validationError');
            _contextManager
                .getContext(task.contextNodeId ?? '')
                ?.log('Observation: $validationError');
            notifyListeners();
            return;
          }

          task.result = result;

          task.status = AgentTaskStatus.completed;
          task.executionHistory.add('Final deliverable produced directly.');

          if (task.contextNodeId != null) {
            final ctx = _contextManager.getContext(task.contextNodeId!);
            if (ctx != null) {
              ctx.log('Turn $turn - Final deliverable produced directly');
              // Generate TOC for structured result access
              ctx.structuredResult = _contextManager.generateTocFromResult(
                task.contextNodeId!,
                task.description,
                result,
              );
            }
          }

          _currentThought = "Delivered final result.";
          _syncWorkflowStatusFromTasks();
          notifyListeners();
          return;
        }

        // Report parse error back to LLM via context for next round
        final errorMsg = xmlResponse.parseError!;
        _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
            'IMPORTANT: $errorMsg';
        task.executionHistory.add("Observation: $errorMsg");
        _contextManager
            .getContext(task.contextNodeId ?? '')
            ?.log('Observation: $errorMsg');
        notifyListeners();
        return;
      }

      // Handle based on action type
      switch (xmlResponse.actionType) {
        case 'answer':
          final answerContent = xmlResponse.content ?? '';
          final validationError = _validateFinalAnswer(task, answerContent);
          if (validationError != null) {
            _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
                'IMPORTANT: $validationError';
            task.executionHistory.add('Observation: $validationError');
            _contextManager
                .getContext(task.contextNodeId ?? '')
                ?.log('Observation: $validationError');
            notifyListeners();
            return;
          }
          task.result = answerContent;
          task.status = AgentTaskStatus.completed;
          // Store full answer content for findings extraction and context propagation
          task.executionHistory.add('Answer: $answerContent');
          final ctx = _contextManager.getContext(task.contextNodeId ?? '');
          ctx?.log('Task Result: $answerContent');
          // Generate TOC for structured result access
          if (ctx != null && task.contextNodeId != null) {
            ctx.structuredResult = _contextManager.generateTocFromResult(
              task.contextNodeId!,
              task.description,
              answerContent,
            );
          }
          _syncWorkflowStatusFromTasks();
          notifyListeners();
          return;

        case 'think':
          final thinkContent = xmlResponse.content ?? '';
          if (thinkContent.isNotEmpty) {
            task.executionHistory.add('Analysis: $thinkContent');
            _contextManager
                .getContext(task.contextNodeId ?? '')
                ?.log('Analysis: $thinkContent');
            _currentThought =
                'Analyzing: ${thinkContent.length > 100 ? '${thinkContent.substring(0, 100)}...' : thinkContent}';
            notifyListeners();
          }
          // Continue loop without calling a tool
          return;

        case 'spawn_subtasks':
          final subtasksList = xmlResponse.parsedContent as List?;
          if (subtasksList != null && subtasksList.isNotEmpty) {
            await _handleSpawnSubtasks(
              task,
              subtasksList.cast<Map<String, dynamic>>(),
            );
            return; // Subtasks spawned, continue loop to wait for them
          }
          task.executionHistory.add('Error: Empty spawn_subtasks list.');
          return;

        case 'tool':
          // Tool handling continues below
          break;

        default:
          task.executionHistory.add(
            "Error: Unknown action type '${xmlResponse.actionType}'.",
          );
          return;
      }

      // Handle tool action
      final requestedToolName = xmlResponse.toolName;
      final args = xmlResponse.parsedContent as Map<String, dynamic>? ?? {};

      if (requestedToolName == null || requestedToolName.isEmpty) {
        task.executionHistory.add("Error: Missing tool name.");
        return;
      }

      final recoveredToolCall = _recoverAgentToolCall(
        requestedToolName,
        args,
        toolsByService: toolsByService,
        fallbackSearchQuery: _inferSearchQueryForTask(task),
      );
      if (recoveredToolCall == null) {
        final errorMsg =
            'Unable to resolve tool call "$requestedToolName". Use <ToolName>call_tool</ToolName> with {"service_name":"...", "tool_name":"...", "params": {...}}.';
        task.executionHistory.add('Observation: $errorMsg');
        _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
            'IMPORTANT: $errorMsg';
        notifyListeners();
        return;
      }

      final serviceName = recoveredToolCall.serviceName;
      final toolName = recoveredToolCall.toolName;
      final params = recoveredToolCall.params;

      // Checkpoint: Before tool call
      _currentCheckpoint = AgentCheckpoint.beforeToolCall;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused before tool call: $serviceName.$toolName';
        task.executionHistory.add(
          'Turn $turn: (paused before tool call: $serviceName.$toolName)',
        );
        _syncWorkflowStatusFromTasks();
        notifyListeners();
        return;
      }

      // Execute Tool
      task.executionHistory.add('Action: Call $serviceName.$toolName');
      _contextManager
          .getContext(task.contextNodeId ?? '')
          ?.log(
            'Action: Calling tool $serviceName.$toolName with args: ${jsonEncode(params)}',
          );
      notifyListeners();

      dynamic result;
      var toolSucceeded = true;
      try {
        if (serviceName == _systemToolServiceName) {
          result = await _executeSystemTool(
            toolName: toolName,
            args: params,
            allowedNativeTools: currentAllowedNative,
          );
        } else {
          final generationContext = GenerationContext(
            values: {'type': 'agent_tool_exec'},
          );
          if (_toolExecutor != null) {
            result = await _toolExecutor!(
              serviceName,
              toolName,
              params,
              generationContext,
            );
          } else {
            final endpoints = await getIt<McpService>().getEndpoints();
            final ids = endpoints.map((e) => e.id).toList();
            result = await McpToolIntegrationService.executeToolCall(
              serviceName: serviceName,
              toolName: toolName,
              parameters: params,
              enabledEndpointIds: ids,
              generationContext: generationContext,
            );
          }
        }
      } catch (e) {
        final errorStr = "Error executing $serviceName.$toolName: $e";
        LoggerService.error(errorStr);
        result = errorStr;
        toolSucceeded = false;

        // Also set as last execution error for explicit visibility
        _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
            "Tool Execution Error: $e";
      }

      // Intercept load_skill results to route to context and resolve tool URIs
      // Handle load_skill results
      bool skillPinned = false;
      if (toolName == 'load_skill' && result is String) {
        final noteId = await _resolveSkillNoteId(params);
        if (noteId.isNotEmpty) {
          skillPinned = await _handleLoadSkillResult(
            noteId,
            result,
            task: task,
          );
        }
      }
      _recordToolExecution(
        task,
        toolName: '$serviceName.$toolName',
        args: params,
        result: result,
        succeeded: toolSucceeded,
      );

      // Shorten skill observation if it was pinned to avoid duplication with <LoadedSkills>
      final String observationText;
      if (toolName == 'load_skill' && skillPinned && result is String) {
        observationText = shortenSkillObservation(
          skillContent: result,
          skillName: _extractSkillName(result),
          pinned: true,
        );
      } else {
        observationText = result.toString();
      }

      task.executionHistory.add("Observation: $observationText");
      // Log observation to hierarchical context
      _contextManager
          .getContext(task.contextNodeId ?? '')
          ?.log('Observation: $observationText');
      notifyListeners();

      // Checkpoint: After tool result
      _currentCheckpoint = AgentCheckpoint.afterToolResult;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused after tool result';
        _syncWorkflowStatusFromTasks();
        notifyListeners();
        return;
      }
    } catch (e) {
      LoggerService.error("Agent Loop Error: $e");
      final errorMsg = "Error: Internal Agent Loop Error: $e";
      task.executionHistory.add(errorMsg);

      // Ensure this fatal error is visible in context for next retry
      _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
          errorMsg;

      // Also log to execution log to keep history straight
      _contextManager.getContext(task.contextNodeId ?? '')?.log(errorMsg);
    }
  }

  /// Builds a tailored system prompt for local models (Gemma).
  String _buildLocalSystemPrompt({
    required AgentTask task,
    required String taskSkillSection,
    required bool hasLoadedSkills,
  }) {
    final isWorkflow = task.name == 'workflow_task';

    if (isWorkflow && hasLoadedSkills) {
      return '''
You are a task-execution agent currently running a specialized workflow. 

CRITICAL RULE: You MUST execute all steps silently. Do NOT generate or output any internal thoughts, reasoning, explanations, or intermediate text. Output ONLY tool calls or the final answer.

A skill workflow has been pre-loaded for you in the <LoadedSkills> section of the conversation context.
You MUST follow the "Workflow" steps in that skill exactly to complete this task. 

DEDUP RULE: The necessary skill is ALREADY LOADED. Do NOT call 'System.load_skill' again for this workflow. Move directly to the first step of the skill's "Workflow" section.

EVIDENCE-BASED EXECUTION:
- You are FORBIDDEN from stating a task is complete unless you have received successful tool observations in this conversation history that prove the work is done.
- If the workflow requires searching, reading, or modifying notes, you MUST call the relevant tools immediately.
- NEVER hallucinate or "fake" a successful result.

PRECISION RULE: When calling tools with note IDs (UUIDs), you MUST copy the ID character-for-character from the context. Do NOT shorten, reformat, or modify UUIDs.

When the workflow is complete based on EVIDENCE, provide a concise markdown summary of the final result.
''';
    }

    // General task prompt
    return '''
You are a task-execution agent that helps users complete tasks using tools and skills.

CRITICAL RULE: You MUST execute all steps silently. Do NOT generate or output any internal thoughts, reasoning, explanations, or intermediate text. Output ONLY tool calls or the final answer.

EVIDENCE-BASED EXECUTION:
- You are FORBIDDEN from stating a task is complete unless you have received successful tool observations in this conversation history that prove the work is done.
- NEVER hallucinate or "fake" a result.

PRECISION RULE: When calling tools with note IDs (UUIDs), you MUST copy the ID character-for-character from the context. Do NOT shorten, reformat, or modify UUIDs.

INSTRUCTIONS:
1. If a relevant skill is already in <LoadedSkills>, follow its instructions exactly.
2. If no relevant skill is loaded, check the "Available Agent Skills" list below. If one matches, use 'System.load_skill' to retrieve its instructions.
3. If no skill applies, use your available tools to complete the task directly.
4. When the task is complete based on EVIDENCE, provide a concise markdown result.

=== AVAILABLE AGENT SKILLS ===
$taskSkillSection
''';
  }

  /// Native function-calling path for local models (Gemma).
  /// Uses actual tool declarations instead of XML-based text parsing.
  Future<void> _performTaskNativeFunctionCalling({
    required AgentTask task,
    required int turn,
    required String globalContext,
    required String deliverableInstructions,
    required String taskSkillSection,
    required Map<String, List<McpTool>> toolsByService,
    required GenerationContext genContext,
    required List<NativeTool> Function() allowedNativeFn,
    required List<NativeTool> currentAllowedNative,
    void Function(String)? onProgressUpdate,
  }) async {
    final hasLoadedSkills =
        _contextManager.rootContext?.loadedSkills.isNotEmpty ?? false;
    final systemPrompt = _buildLocalSystemPrompt(
      task: task,
      taskSkillSection: taskSkillSection,
      hasLoadedSkills: hasLoadedSkills,
    );

    final turnGuidance = turn == 1
        ? 'Turn $turn: Analyze the task and context. Decide if you need to call a tool or load a skill to begin. If you already have all necessary information, you may provide the final answer directly.'
        : 'Turn $turn: Continue with the next step based on the tool observations above. If the task is complete, provide the final answer.';

    // User message: task + context + compact instructions (no XML format, no tool catalog)
    final userPrompt = '''
Task: "${task.description}"

$globalContext
$deliverableInstructions

$turnGuidance

Call tools when you need information. When you have a complete answer, respond with the result as markdown text.''';

    final response = await _generateLlmResponseWithTools(
      systemPrompt,
      userPrompt,
      toolsByService,
      context: genContext,
    );

    // Checkpoint: After LLM response
    _currentCheckpoint = AgentCheckpoint.afterLlmResponse;
    notifyListeners();
    if (_isPaused) {
      task.status = AgentTaskStatus.paused;
      _currentThought = 'Paused after LLM response';
      task.executionHistory.add('Turn $turn: (paused after LLM response)');
      _syncWorkflowStatusFromTasks();
      notifyListeners();
      return;
    }

    final textResponse = response['text']?.toString() ?? '';
    final functionCalls = response['function_calls'] as List?;

    // Extract thought from text portion (model may still include <MyThought>)
    final thinkResult = stripThinkTags(textResponse);
    String thought = '';
    if (thinkResult.thinkContent != null &&
        thinkResult.thinkContent!.isNotEmpty) {
      thought = thinkResult.thinkContent!;
    }
    // Also check for <MyThought> in the cleaned text
    final myThoughtMatch = RegExp(
      r'<MyThought>(.*?)</MyThought>',
      dotAll: true,
    ).firstMatch(thinkResult.cleanedContent);
    if (myThoughtMatch != null) {
      thought = myThoughtMatch.group(1)?.trim() ?? thought;
    }

    _currentThought =
        thought.isNotEmpty ? thought : 'Executing (native tool call)...';
    onProgressUpdate?.call(_currentThought!);
    notifyListeners();

    task.executionHistory.add('Turn $turn:');
    if (thought.isNotEmpty) {
      task.executionHistory.add('Thought: $thought');
    }
    if (task.contextNodeId != null) {
      _contextManager
          .getContext(task.contextNodeId!)
          ?.log('Turn $turn - Thought: $_currentThought');
    }

    // Process function calls if present
    if (functionCalls != null && functionCalls.isNotEmpty) {
      final fc = functionCalls.first as Map<String, dynamic>;
      final fcName = fc['name']?.toString() ?? '';
      final fcArgs = fc['args'] as Map<String, dynamic>? ?? {};

      final recoveredToolCall = _recoverAgentToolCall(
        fcName,
        fcArgs,
        toolsByService: toolsByService,
        fallbackSearchQuery: _inferSearchQueryForTask(task),
      );
      if (recoveredToolCall == null) {
        final errorMsg =
            'Unable to resolve tool call "$fcName". Available tools: '
            '${toolsByService.values.expand((t) => t).map((t) => t.name).join(", ")}';
        task.executionHistory.add('Observation: $errorMsg');
        _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
            'IMPORTANT: $errorMsg';
        notifyListeners();
        return;
      }

      final serviceName = recoveredToolCall.serviceName;
      final toolName = recoveredToolCall.toolName;
      final params = recoveredToolCall.params;

      // Checkpoint: Before tool call
      _currentCheckpoint = AgentCheckpoint.beforeToolCall;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused before tool call: $serviceName.$toolName';
        task.executionHistory.add(
          'Turn $turn: (paused before tool call: $serviceName.$toolName)',
        );
        _syncWorkflowStatusFromTasks();
        notifyListeners();
        return;
      }

      // Execute tool
      task.executionHistory.add('Action: Call $serviceName.$toolName');
      _contextManager
          .getContext(task.contextNodeId ?? '')
          ?.log(
            'Action: Calling tool $serviceName.$toolName with args: ${jsonEncode(params)}',
          );
      notifyListeners();

      dynamic result;
      var toolSucceeded = true;
      try {
        if (serviceName == _systemToolServiceName) {
          result = await _executeSystemTool(
            toolName: toolName,
            args: params,
            allowedNativeTools: currentAllowedNative,
          );
        } else {
          final generationContext = GenerationContext(
            values: {'type': 'agent_tool_exec'},
          );
          if (_toolExecutor != null) {
            result = await _toolExecutor!(
              serviceName,
              toolName,
              params,
              generationContext,
            );
          } else {
            final endpoints = await getIt<McpService>().getEndpoints();
            final ids = endpoints.map((e) => e.id).toList();
            result = await McpToolIntegrationService.executeToolCall(
              serviceName: serviceName,
              toolName: toolName,
              parameters: params,
              enabledEndpointIds: ids,
              generationContext: generationContext,
            );
          }
        }
      } catch (e) {
        final errorStr = 'Error executing $serviceName.$toolName: $e';
        LoggerService.error(errorStr);
        result = errorStr;
        toolSucceeded = false;
      }

      // Handle load_skill results
      bool skillPinned = false;
      if (toolName == 'load_skill' && result is String) {
        final noteId = await _resolveSkillNoteId(params);
        if (noteId.isNotEmpty) {
          skillPinned = await _handleLoadSkillResult(
            noteId,
            result,
            task: task,
          );
        }
      }

      _recordToolExecution(
        task,
        toolName: '$serviceName.$toolName',
        args: params,
        result: result,
        succeeded: toolSucceeded,
      );

      final String observationText;
      if (toolName == 'load_skill' && skillPinned && result is String) {
        observationText = shortenSkillObservation(
          skillContent: result,
          skillName: _extractSkillName(result),
          pinned: true,
        );
      } else {
        observationText = result.toString();
      }

      task.executionHistory.add('Observation: $observationText');
      _contextManager
          .getContext(task.contextNodeId ?? '')
          ?.log('Observation: $observationText');
      notifyListeners();

      // Checkpoint: After tool result
      _currentCheckpoint = AgentCheckpoint.afterToolResult;
      notifyListeners();
      if (_isPaused) {
        task.status = AgentTaskStatus.paused;
        _currentThought = 'Paused after tool result';
        _syncWorkflowStatusFromTasks();
        notifyListeners();
        return;
      }
      return;
    }

    // No function calls — model responded with text only.
    // Try XML fallback (model may have produced XML in text).
    final cleanedText = thinkResult.cleanedContent.replaceFirst(
      RegExp(r'<MyThought>.*?</MyThought>\s*', dotAll: true),
      '',
    ).trim();
    final xmlResponse = parseXmlAgentResponse(cleanedText);

    if (!xmlResponse.hasError && xmlResponse.actionType == 'tool') {
      // Model produced XML tool action in text — process via XML path
      final requestedToolName = xmlResponse.toolName;
      final args = xmlResponse.parsedContent as Map<String, dynamic>? ?? {};
      if (requestedToolName != null && requestedToolName.isNotEmpty) {
        final recoveredToolCall = _recoverAgentToolCall(
          requestedToolName,
          args,
          toolsByService: toolsByService,
          fallbackSearchQuery: _inferSearchQueryForTask(task),
        );
        if (recoveredToolCall != null) {
          // Re-enter this method's tool execution path would duplicate code.
          // Instead, record a corrective error so the next turn uses function calling.
          final errorMsg =
              'Use native function calling instead of XML. Call call_tool directly.';
          task.executionHistory.add('Observation: $errorMsg');
          _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
              errorMsg;
          notifyListeners();
          return;
        }
      }
    }

    // Treat as final answer if deliverable or if substantial text
    if (task.isFinalDeliverable && cleanedText.isNotEmpty) {
      final validationError = _validateFinalAnswer(task, cleanedText);
      if (validationError != null) {
        _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
            'IMPORTANT: $validationError';
        task.executionHistory.add('Observation: $validationError');
        notifyListeners();
        return;
      }
      task.result = cleanedText;
      task.status = AgentTaskStatus.completed;
      task.executionHistory.add('Final deliverable produced directly.');
      if (task.contextNodeId != null) {
        final ctx = _contextManager.getContext(task.contextNodeId!);
        if (ctx != null) {
          ctx.log('Turn $turn - Final deliverable produced directly');
          ctx.structuredResult = _contextManager.generateTocFromResult(
            task.contextNodeId!,
            task.description,
            cleanedText,
          );
        }
      }
      _currentThought = 'Delivered final result.';
      _syncWorkflowStatusFromTasks();
      notifyListeners();
      return;
    }

    // Non-deliverable text response — treat as a think action
    if (cleanedText.isNotEmpty) {
      task.executionHistory.add('Analysis: $cleanedText');
      _contextManager
          .getContext(task.contextNodeId ?? '')
          ?.log('Analysis: $cleanedText');
    } else {
      // Empty response — report error
      task.executionHistory.add(
        'Observation: Model returned empty response with no tool calls.',
      );
      _contextManager.getContext(task.contextNodeId ?? '')?.lastError =
          'IMPORTANT: You must call a tool or provide an answer. Do not respond with empty text.';
    }
    notifyListeners();
  }

  /// Called when a load_skill tool call returns successfully.
  /// Routes skill content to the loadedSkills context region and resolves tool URIs.
  /// Returns true if the skill was newly pinned (not a duplicate), false otherwise.
  Future<bool> _handleLoadSkillResult(
    String noteId,
    String content, {
    AgentTask? task,
  }) async {
    final root = _contextManager.rootContext;
    final alreadyLoaded =
        root?.loadedSkills.any((s) => s.noteId == noteId) ?? false;

    // Add to pinned context region (deduplicated inside addLoadedSkill)
    _contextManager.addLoadedSkill(noteId, content);

    // Check if it was actually added (not just deduplicated)
    final nowLoaded =
        _contextManager.rootContext?.loadedSkills.any(
          (s) => s.noteId == noteId,
        ) ??
        false;
    final newlyPinned = !alreadyLoaded && nowLoaded;

    // Extract and resolve tool URIs from skill content
    final skillService = getIt<SkillService>();
    final uris = skillService.extractToolUris(content);
    final newToolNames = <String>[];
    final allMentionedToolNames = <String>[];

    for (final uri in uris) {
      final parsed = skillService.parseToolUri(uri);
      if (parsed == null) continue;
      final tools = await _resolveSkillToolUri(parsed);
      for (final resolved in tools) {
        final tool = resolved.tool;
        allMentionedToolNames.add(tool.name);

        // Deduplicate against all available tools to prevent list bloat/drift
        final isNative = nativeTools.any((t) => t.name == tool.name);
        final isExternal = _externalTools.values
            .expand((x) => x)
            .any((t) => t.name == tool.name);
        final isDiscovered =
            _skillDiscoveredTools.any((t) => t.name == tool.name);

        if (!isNative && !isExternal && !isDiscovered) {
          _skillDiscoveredTools.add(tool);
          _skillToolServiceNames[tool.name] = resolved.serviceName;
          newToolNames.add(tool.name);
        }
      }
    }

    // If we have a restricted tool list, add ALL mentioned tools to it
    if (task != null &&
        task.allowedTools.isNotEmpty &&
        allMentionedToolNames.isNotEmpty) {
      for (final name in allMentionedToolNames) {
        if (!task.allowedTools.contains(name)) {
          task.allowedTools.add(name);
        }
      }
    }

    // Log trace annotation when new tools were injected
    if (newToolNames.isNotEmpty) {
      _promoteSkillDiscoveredTools(newToolNames);
      _contextManager.rootContext?.log(
        'Skill loaded: injected tools [${newToolNames.join(', ')}]',
      );
    }
    notifyListeners();

    return newlyPinned;
  }

  String _extractSkillName(String content) {
    final firstLine = content
        .split('\n')
        .firstWhere(
          (line) => line.trim().isNotEmpty,
          orElse: () => 'Unknown skill',
        );
    return firstLine.replaceAll(RegExp(r'^#+\s*Skill:\s*'), '').trim();
  }

  /// Resolve a parsed tool URI to a list of tools paired with service names.
  Future<List<_ResolvedSkillTool>> _resolveSkillToolUri(
    ({String namespace, String id, String? function}) parsed,
  ) async {
    switch (parsed.namespace) {
      case 'builtin':
        // Find in native tools list, convert to McpTool format
        final tool = _nativeTools.where((t) => t.name == parsed.id).firstOrNull;
        if (tool == null) return [];
        return [
          _ResolvedSkillTool(
            serviceName: _systemToolServiceName,
            tool: McpTool(
              name: tool.name,
              description: tool.description,
              inputSchema: tool.inputSchema,
            ),
          ),
        ];

      case 'user_defined':
        // Find UserApp by UUID, load its bundle and convert to McpTools
        final allApps = await _databaseService.getAllUserApps();
        final app = allApps.where((a) => a.uuid == parsed.id).firstOrNull;
        if (app == null || app.selectedRevisionId == null) return [];
        final revision = await getIt<UserAppService>().getAppRevision(
          app.selectedRevisionId!,
        );
        if (revision == null) return [];
        final bundle = await AiToolService.loadAppBundle(
          app: app,
          revision: revision,
        );
        if (bundle == null) return [];
        final allTools = bundle.toMcpTools();
        if (parsed.function != null) {
          return allTools
              .where((t) => t.name == parsed.function)
              .map(
                (tool) => _ResolvedSkillTool(
                  serviceName: bundle.serviceName,
                  tool: tool,
                ),
              )
              .toList();
        }
        return allTools
            .map(
              (tool) => _ResolvedSkillTool(
                serviceName: bundle.serviceName,
                tool: tool,
              ),
            )
            .toList();

      case 'mcp':
        // Find endpoint by name, get its tools (cached or refresh)
        final mcpService = getIt<McpService>();
        final endpoints = await mcpService.getEndpoints();
        final endpoint = endpoints
            .where((e) => e.name == parsed.id)
            .firstOrNull;
        if (endpoint == null) return [];
        final cache = await mcpService.getCachedTools(endpoint.id);
        final allTools =
            cache?.tools ?? (await mcpService.refreshTools(endpoint.id)).tools;
        if (parsed.function != null) {
          return allTools
              .where((t) => t.name == parsed.function)
              .map(
                (tool) =>
                    _ResolvedSkillTool(serviceName: endpoint.name, tool: tool),
              )
              .toList();
        }
        return allTools
            .map(
              (tool) =>
                  _ResolvedSkillTool(serviceName: endpoint.name, tool: tool),
            )
            .toList();

      default:
        return [];
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
    if (parentTask.depth >= _cachedMaxSubtaskDepth) {
      parentTask.executionHistory.add(
        'Cannot spawn subtasks: maximum depth ($_cachedMaxSubtaskDepth) reached. Use "think" to analyze or use "tool" to carry out tasks in current context instead.',
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
        allowedTools: parentTask.allowedTools,
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
    return await _aiService.generateWithAttachments(
      prompt,
      [],
      generationContext: genContext,
    );
  }
}

class _PendingWorkflow {
  final ResolvedBinding binding;
  final Note note;
  _PendingWorkflow(this.binding, this.note);
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
