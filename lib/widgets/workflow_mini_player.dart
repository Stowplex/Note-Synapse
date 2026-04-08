// lib/widgets/workflow_mini_player.dart
import 'package:flutter/material.dart';
import '../services/agent_service.dart';

class WorkflowMiniPlayer extends StatefulWidget {
  final WorkflowStatusSnapshot? activeStatus;
  final List<PendingWorkflowInfo> pendingWorkflows;
  final String? currentThought;
  final VoidCallback onStop;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onViewLog;
  final void Function(int index) onCancelPending;
  final VoidCallback onDismiss;

  const WorkflowMiniPlayer({
    super.key,
    required this.activeStatus,
    required this.pendingWorkflows,
    required this.currentThought,
    required this.onStop,
    required this.onPause,
    required this.onResume,
    required this.onViewLog,
    required this.onCancelPending,
    required this.onDismiss,
  });

  @override
  State<WorkflowMiniPlayer> createState() => _WorkflowMiniPlayerState();
}

class _WorkflowMiniPlayerState extends State<WorkflowMiniPlayer> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // Auto-expand on initial build if already paused
    final status = widget.activeStatus;
    if (status != null && status.isPaused) {
      _expanded = true;
    }
  }

  @override
  void didUpdateWidget(WorkflowMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-expand when paused
    final status = widget.activeStatus;
    if (status != null && status.isPaused && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.activeStatus;
    if (status == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final isRunning = status.state == WorkflowExecutionState.running;
    final isPaused = status.isPaused;
    final isCompleted = status.state == WorkflowExecutionState.completed;
    final isFailed = status.state == WorkflowExecutionState.failed;

    final bgColor = isPaused
        ? colorScheme.tertiaryContainer
        : isFailed
            ? colorScheme.errorContainer
            : isCompleted
                ? colorScheme.primaryContainer
                : colorScheme.secondaryContainer;

    final fgColor = isPaused
        ? colorScheme.onTertiaryContainer
        : isFailed
            ? colorScheme.onErrorContainer
            : isCompleted
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSecondaryContainer;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: Material(
        color: bgColor,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCollapsedRow(status, fgColor, isRunning, isPaused, isCompleted, isFailed),
                if (_expanded) ...[
                  const SizedBox(height: 8),
                  _buildActions(status, colorScheme),
                  if (widget.pendingWorkflows.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildQueue(fgColor),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedRow(
    WorkflowStatusSnapshot status,
    Color fgColor,
    bool isRunning,
    bool isPaused,
    bool isCompleted,
    bool isFailed,
  ) {
    final icon = isRunning
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: fgColor),
          )
        : Icon(
            isPaused
                ? Icons.warning_amber_rounded
                : isCompleted
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
            size: 18,
            color: fgColor,
          );

    final title = status.noteTitle.isNotEmpty
        ? '${status.matchedTag}: "${status.noteTitle}"'
        : status.matchedTag;

    final subtitle = widget.currentThought ?? status.message;
    final turnInfo = status.maxTurns > 0
        ? 'Turn ${status.turnsUsed}/${status.maxTurns}'
        : null;

    return Row(
      children: [
        icon,
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.w600, color: fgColor, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                turnInfo != null ? '$turnInfo — $subtitle' : subtitle,
                style: TextStyle(color: fgColor.withValues(alpha: 0.8), fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (widget.pendingWorkflows.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: fgColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '+${widget.pendingWorkflows.length}',
              style: TextStyle(color: fgColor, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        if (isRunning) ...[
          const SizedBox(width: 8),
          InkWell(
            onTap: widget.onStop,
            child: Icon(Icons.stop, size: 20, color: fgColor),
          ),
        ],
        if (isFailed || isCompleted) ...[
          const SizedBox(width: 8),
          InkWell(
            onTap: widget.onDismiss,
            child: Icon(Icons.close, size: 20, color: fgColor),
          ),
        ],
      ],
    );
  }

  Widget _buildActions(WorkflowStatusSnapshot status, ColorScheme colorScheme) {
    final isPausedTurnLimit = status.state == WorkflowExecutionState.pausedTurnLimit;
    final isPaused = status.isPaused;
    final isRunning = status.state == WorkflowExecutionState.running;

    return Row(
      children: [
        if (isRunning) ...[
          Expanded(
            child: OutlinedButton(
              onPressed: widget.onStop,
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.error,
                side: BorderSide(color: colorScheme.error),
              ),
              child: const Text('Stop'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: widget.onPause,
              child: const Text('Pause'),
            ),
          ),
        ],
        if (isPaused) ...[
          Expanded(
            child: OutlinedButton(
              onPressed: widget.onStop,
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.error,
                side: BorderSide(color: colorScheme.error),
              ),
              child: const Text('Abort'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: widget.onResume,
              child: Text(isPausedTurnLimit ? 'Add Turns' : 'Resume'),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: widget.onViewLog,
            child: const Text('View Log'),
          ),
        ),
      ],
    );
  }

  Widget _buildQueue(Color fgColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Queued:',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: fgColor,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        ...widget.pendingWorkflows.asMap().entries.map((entry) {
          final idx = entry.key;
          final pw = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Text(
                  '${idx + 1}. ',
                  style: TextStyle(color: fgColor, fontSize: 12),
                ),
                Expanded(
                  child: Text(
                    '${pw.matchedTag}: "${pw.noteTitle}"',
                    style: TextStyle(color: fgColor, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: () => widget.onCancelPending(idx),
                  child: Icon(Icons.close, size: 16, color: fgColor),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
