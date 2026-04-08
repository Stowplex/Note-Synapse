// lib/widgets/workflow_shell.dart
import 'package:flutter/material.dart';

import '../screens/agent_trace_screen.dart';
import '../services/agent_service.dart';
import '../services/service_locator.dart';
import 'workflow_mini_player.dart';

/// Root-level wrapper that renders the [WorkflowMiniPlayer] on all screens.
///
/// Listens to [AgentService] and passes current workflow state to [WorkflowMiniPlayer].
/// Lives above navigation so the mini-player persists across screen changes.
class WorkflowShell extends StatefulWidget {
  final Widget child;

  const WorkflowShell({super.key, required this.child});

  @override
  State<WorkflowShell> createState() => _WorkflowShellState();
}

class _WorkflowShellState extends State<WorkflowShell> {
  AgentService get _agentService => getIt<AgentService>();

  /// Tracks dismissed terminal states so mini-player hides after user dismisses.
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _agentService.addListener(_onAgentStateChanged);
  }

  @override
  void dispose() {
    _agentService.removeListener(_onAgentStateChanged);
    super.dispose();
  }

  void _onAgentStateChanged() {
    final status = _agentService.activeWorkflowStatus;
    // Reset dismissed flag when a new workflow starts
    if (status != null && status.state == WorkflowExecutionState.running && _dismissed) {
      _dismissed = false;
    }
    if (mounted) setState(() {});
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
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AgentTraceScreen()),
    );
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
