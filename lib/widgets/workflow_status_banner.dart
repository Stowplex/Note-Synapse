import 'package:flutter/material.dart';

import '../services/agent_service.dart';

class WorkflowStatusBanner extends StatelessWidget {
  final WorkflowStatusSnapshot status;
  final VoidCallback onAbort;
  final VoidCallback onResume;
  final VoidCallback onBail;

  const WorkflowStatusBanner({
    super.key,
    required this.status,
    required this.onAbort,
    required this.onResume,
    required this.onBail,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPausedTurnLimit =
        status.state == WorkflowExecutionState.pausedTurnLimit;
    final isPausedManual = status.state == WorkflowExecutionState.pausedManual;
    final isPaused = isPausedTurnLimit || isPausedManual;

    return Material(
      color: isPaused
          ? colorScheme.tertiaryContainer
          : colorScheme.secondaryContainer,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isPaused ? colorScheme.tertiary : colorScheme.secondary,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isPaused ? Icons.warning_amber_rounded : Icons.sync,
                  size: 18,
                  color: isPaused
                      ? colorScheme.onTertiaryContainer
                      : colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status.message,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isPaused
                          ? colorScheme.onTertiaryContainer
                          : colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            if (isPaused) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onAbort,
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
                      onPressed: onResume,
                      child: Text(isPausedTurnLimit ? 'Add Turns' : 'Resume'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onBail,
                      child: const Text('Bail'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
