// lib/widgets/workflow_shell.dart
import 'package:flutter/material.dart';

import '../screens/agent_trace_screen.dart';
import '../services/agent_service.dart';
import '../services/approval_service.dart';
import '../services/built_in_tools_service.dart';
import '../services/mcp_service.dart';
import '../services/mcp_tool_integration_service.dart';
import '../services/service_locator.dart';
import '../utils/global_keys.dart';
import '../widgets/approval_dialog.dart';
import '../services/content_ingestion_service.dart';
import '../widgets/local_model_workflow_warning_dialog.dart';
import 'workflow_mini_player.dart';

/// Root-level wrapper that renders the [WorkflowMiniPlayer] on all screens
/// and wires a [ToolExecutor] for tag-triggered workflows.
///
/// Listens to [AgentService] and:
/// - Provides a [ToolExecutor] (System + MCP tools) when a workflow starts
/// - Releases the executor when all workflows finish
/// - Registers [ApprovalService.onApprovalRequest] for workflow tool approvals
/// - Renders child + [WorkflowMiniPlayer] in a [Column]
///
/// Lives above navigation so the mini-player persists across screen changes.
class WorkflowShell extends StatefulWidget {
  final Widget child;

  const WorkflowShell({super.key, required this.child});

  @override
  State<WorkflowShell> createState() => _WorkflowShellState();
}

class _WorkflowShellState extends State<WorkflowShell> {
  AgentService get _agentService => getIt<AgentService>();

  /// Whether the shell currently owns the tool executor.
  bool _shellOwnsExecutor = false;

  /// Tracks dismissed terminal states so mini-player hides after user dismisses.
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    ApprovalService.fallbackApprovalRequest = _showApprovalDialog;
    ContentIngestionService.onLocalModelApprovalRequired = _showLocalModelWorkflowDialog;
    _agentService.addListener(_onAgentStateChanged);
  }

  @override
  void dispose() {
    if (identical(
      ApprovalService.fallbackApprovalRequest,
      _showApprovalDialog,
    )) {
      ApprovalService.fallbackApprovalRequest = null;
    }
    if (identical(
      ContentIngestionService.onLocalModelApprovalRequired,
      _showLocalModelWorkflowDialog,
    )) {
      ContentIngestionService.onLocalModelApprovalRequired = null;
    }
    _agentService.removeListener(_onAgentStateChanged);
    super.dispose();
  }

  void _onAgentStateChanged() {
    final status = _agentService.activeWorkflowStatus;

    if (status != null &&
        status.state == WorkflowExecutionState.running &&
        !_shellOwnsExecutor) {
      // New workflow started — wire executor and reset dismissed flag
      _wireToolExecutor();
      _dismissed = false;
    }

    if ((status == null || status.isTerminal) &&
        _agentService.pendingWorkflows.isEmpty &&
        _shellOwnsExecutor) {
      // All workflows done — release executor
      _releaseToolExecutor();
    }

    if (mounted) setState(() {});
  }

  void _wireToolExecutor() {
    _agentService.updateToolExecutor(_createToolExecutor());
    _shellOwnsExecutor = true;
  }

  void _releaseToolExecutor() {
    _shellOwnsExecutor = false;
  }

  Future<LocalModelWorkflowApproval> _showLocalModelWorkflowDialog() async {
    if (!mounted) return LocalModelWorkflowApproval.cancel;
    final context = navigatorKey.currentContext;
    if (context == null) return LocalModelWorkflowApproval.cancel;
    final result = await LocalModelWorkflowWarningDialog.show(context);
    return result ?? LocalModelWorkflowApproval.cancel;
  }

  Future<ApprovalResult> _showApprovalDialog(ApprovalRequest request) async {
    if (!mounted) {
      throw StateError('Workflow shell is not mounted');
    }
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      throw StateError('Navigator unavailable for approval dialog');
    }
    return ApprovalDialog.show(navigator, request);
  }

  ToolExecutor _createToolExecutor() {
    return (serviceName, toolName, params, ctx) async {
      // Handle System Tools (native tools from AgentService)
      if (serviceName == BuiltInToolsService.systemToolsServiceKey) {
        final nativeTool = _agentService.nativeTools
            .where((t) => t.name == toolName)
            .firstOrNull;
        if (nativeTool != null) {
          final result = await nativeTool.execute(params);
          return result is String ? result : result.toString();
        }
        return 'Error: System tool "$toolName" not found';
      }
      // Handle MCP Tools
      final endpoints = await getIt<McpService>().getEndpoints();
      return McpToolIntegrationService.executeToolCall(
        serviceName: serviceName,
        toolName: toolName,
        parameters: params,
        enabledEndpointIds: endpoints.map((e) => e.id).toList(),
        generationContext: ctx,
      );
    };
  }

  void _handleStop() {
    final status = _agentService.activeWorkflowStatus;
    if (status != null) {
      _agentService.abortTask(status.taskId);
    }
  }

  void _handlePause() {
    _agentService.pauseExecution();
  }

  void _handleResume() {
    final status = _agentService.activeWorkflowStatus;
    if (status == null) return;
    _agentService.resumeTask(
      status.taskId,
      increaseLimit: status.state == WorkflowExecutionState.pausedTurnLimit,
    );
  }

  void _handleViewLog() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AgentTraceScreen()));
  }

  void _handleDismiss() {
    setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    final status = _agentService.activeWorkflowStatus;
    final showMiniPlayer = status != null && !_dismissed;

    return Column(
      children: [
        Expanded(child: widget.child),
        WorkflowMiniPlayer(
          activeStatus: showMiniPlayer ? status : null,
          pendingWorkflows: _agentService.pendingWorkflows,
          currentThought: _agentService.currentThought,
          onStop: _handleStop,
          onPause: _handlePause,
          onResume: _handleResume,
          onViewLog: _handleViewLog,
          onCancelPending: _agentService.cancelPendingWorkflow,
          onDismiss: _handleDismiss,
        ),
      ],
    );
  }
}
