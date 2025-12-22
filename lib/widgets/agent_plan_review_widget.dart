import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/agent_service.dart';
import '../models/agent_task.dart';

class AgentPlanReviewWidget extends StatefulWidget {
  final VoidCallback onProceed;

  const AgentPlanReviewWidget({super.key, required this.onProceed});

  @override
  State<AgentPlanReviewWidget> createState() => _AgentPlanReviewWidgetState();
}

class _AgentPlanReviewWidgetState extends State<AgentPlanReviewWidget> {
  final TextEditingController _feedbackController = TextEditingController();
  final Map<String, TextEditingController> _itemControllers = {};
  bool _isRevising = false;

  @override
  void dispose() {
    _feedbackController.dispose();
    for (final controller in _itemControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _handleRevise() async {
    final generalFeedback = _feedbackController.text.trim();
    // Gather item specific feedback is already in the mode (userComment) if we bound it?
    // Actually, we should save the text from controllers to the userComment field before revising.
    final agentService = context.read<AgentService>();
    for (final task in agentService.tasks) {
      if (_itemControllers.containsKey(task.id)) {
        task.userComment = _itemControllers[task.id]!.text.trim();
      }
    }

    // Check if we have anything to revise
    if (generalFeedback.isEmpty &&
        agentService.tasks.every(
          (t) => t.userComment == null || t.userComment!.isEmpty,
        )) {
      return;
    }

    setState(() => _isRevising = true);
    try {
      await agentService.revisePlan(generalFeedback);
      _feedbackController.clear();
      _itemControllers
          .clear(); // Clear item controllers as tasks are re-generated
    } finally {
      if (mounted) {
        setState(() => _isRevising = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AgentService>(
      builder: (context, agentService, child) {
        final tasks = agentService.tasks;
        final isRunning = agentService.isRunning;

        // If agent is working (generating plan or revising), show loading
        if (agentService.currentThought != null &&
            (agentService.currentThought!.contains('Generating') ||
                agentService.currentThought!.contains('Revising'))) {
          return Card(
            margin: const EdgeInsets.all(8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(agentService.currentThought ?? 'Working...'),
                ],
              ),
            ),
          );
        }

        return Card(
          elevation: 4,
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.assignment_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Proposed Plan',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (tasks.isEmpty)
                  const Text('No plan generated yet.')
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: tasks.length,
                    separatorBuilder: (_, __) => const Divider(height: 8),
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      // Initialize controller if needed
                      if (!_itemControllers.containsKey(task.id)) {
                        _itemControllers[task.id] = TextEditingController(
                          text: task.userComment,
                        );
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 10,
                                backgroundColor: Colors.grey.shade200,
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(task.description),
                                    if (task.toolName != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          'Using: ${task.toolName}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.secondary,
                                                fontStyle: FontStyle.italic,
                                              ),
                                        ),
                                      ),
                                    if (task.status ==
                                        AgentTaskStatus.inProgress)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Row(
                                          children: [
                                            const SizedBox(
                                              width: 12,
                                              height: 12,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                agentService.currentThought ??
                                                    'Running...',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: Theme.of(
                                                        context,
                                                      ).colorScheme.primary,
                                                      fontStyle:
                                                          FontStyle.italic,
                                                    ),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    if (task.status ==
                                            AgentTaskStatus.completed &&
                                        task.result != null)
                                      Container(
                                        width: double.infinity,
                                        margin: const EdgeInsets.only(top: 8),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.outlineVariant,
                                          ),
                                        ),
                                        child: Text(
                                          'Result: ${task.result}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                fontFamily: 'monospace',
                                                fontSize: 11,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                          maxLines: 10,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    if (task.status == AgentTaskStatus.failed &&
                                        task.result != null)
                                      Container(
                                        width: double.infinity,
                                        margin: const EdgeInsets.only(top: 8),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.errorContainer,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                        ),
                                        child: Text(
                                          'Error: ${task.result}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                fontFamily: 'monospace',
                                                fontSize: 11,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onErrorContainer,
                                              ),
                                        ),
                                      ),
                                    const SizedBox(height: 4),
                                    TextField(
                                      controller: _itemControllers[task.id],
                                      decoration: InputDecoration(
                                        hintText: 'Add comment/refinement...',
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                        hintStyle: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant
                                              .withOpacity(0.6),
                                        ),
                                      ),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (task.status == AgentTaskStatus.paused)
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.tertiary,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '⚠️ ${task.result}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onTertiaryContainer,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () =>
                                              agentService.abortTask(task.id),
                                          style: OutlinedButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                            side: BorderSide(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.error,
                                            ),
                                            foregroundColor: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                          child: const Text('Abort'),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: ElevatedButton(
                                          onPressed: () =>
                                              agentService.resumeTask(
                                                task.id,
                                                increaseLimit: true,
                                              ),
                                          style: ElevatedButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                          ),
                                          child: const Text('+10 Turns'),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () => agentService
                                              .concludeTask(task.id),
                                          style: OutlinedButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                          ),
                                          child: const Text('Bail'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'General Feedback',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _feedbackController,
                  decoration: const InputDecoration(
                    hintText: 'e.g., "Also add a step to translate to Spanish"',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  maxLines: 2,
                  minLines: 1,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: (_isRevising || isRunning)
                          ? null
                          : _handleRevise,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Revise Plan'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: (_isRevising || isRunning)
                          ? null
                          : () {
                              // Ensure any pending comment edits are saved?
                              // Not strictly necessary as executePlan uses strict tasks list
                              // but good practice if we were persisting.
                              widget.onProceed();
                            },
                      icon: isRunning
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(isRunning ? 'Executing...' : 'Proceed'),
                    ),
                  ],
                ),
                if (agentService.finalAnswer != null)
                  Container(
                    margin: const EdgeInsets.only(top: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.check_circle_outline,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Conclusion',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          agentService.finalAnswer!,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
