import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/agent_task.dart';
import '../models/context_node.dart';
import '../services/agent_service.dart';
import 'add_note_dialog.dart';

/// Widget for displaying hierarchical agent task execution.
/// Shows a tree structure of tasks with their context nodes,
/// execution status, and real-time progress.
class AgentTaskTreeWidget extends StatefulWidget {
  /// Called when user wants to expand/view details.
  final Function(AgentTask task)? onTaskTap;

  /// Called when user wants to view full execution log.
  final Function(ContextNode context)? onContextTap;

  const AgentTaskTreeWidget({super.key, this.onTaskTap, this.onContextTap});

  @override
  State<AgentTaskTreeWidget> createState() => _AgentTaskTreeWidgetState();
}

class _AgentTaskTreeWidgetState extends State<AgentTaskTreeWidget>
    with SingleTickerProviderStateMixin {
  final Set<String> _expandedNodes = {};
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AgentService>(
      builder: (context, agentService, child) {
        final tasks = agentService.tasks;
        final rootContext = agentService.contextManager.rootContext;
        final objective = agentService.currentObjective;

        if (tasks.isEmpty && rootContext == null) {
          return const SizedBox.shrink();
        }

        return Card(
          elevation: 2,
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header with objective
                _buildHeader(context, objective, agentService.isRunning),
                const SizedBox(height: 12),
                // Task tree
                _buildTaskTree(context, tasks, agentService),
                // Current thought indicator
                if (agentService.isRunning &&
                    agentService.currentThought != null)
                  _buildCurrentThought(context, agentService.currentThought!),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, String? objective, bool isRunning) {
    return Row(
      children: [
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Icon(
              Icons.account_tree_rounded,
              color: isRunning
                  ? Color.lerp(
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.tertiary,
                      _pulseController.value,
                    )
                  : Theme.of(context).colorScheme.primary,
            );
          },
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Agent Execution',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              if (objective != null)
                Text(
                  objective,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (isRunning)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
      ],
    );
  }

  Widget _buildTaskTree(
    BuildContext context,
    List<AgentTask> tasks,
    AgentService agentService,
  ) {
    // Group tasks by parent
    final rootTasks = tasks.where((t) => t.isRootTask).toList();
    final tasksByParent = <String, List<AgentTask>>{};
    for (final task in tasks) {
      if (task.parentTaskId != null) {
        tasksByParent.putIfAbsent(task.parentTaskId!, () => []).add(task);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < rootTasks.length; i++)
          _buildTaskNode(
            context,
            rootTasks[i],
            tasksByParent,
            agentService,
            isLast: i == rootTasks.length - 1,
            depth: 0,
          ),
      ],
    );
  }

  Widget _buildTaskNode(
    BuildContext context,
    AgentTask task,
    Map<String, List<AgentTask>> tasksByParent,
    AgentService agentService, {
    required bool isLast,
    required int depth,
  }) {
    final children = tasksByParent[task.id] ?? [];
    final hasChildren = children.isNotEmpty;
    final isExpanded = _expandedNodes.contains(task.id);
    final contextNode = task.contextNodeId != null
        ? agentService.contextManager.getContext(task.contextNodeId!)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: hasChildren
              ? () {
                  setState(() {
                    if (isExpanded) {
                      _expandedNodes.remove(task.id);
                    } else {
                      _expandedNodes.add(task.id);
                    }
                  });
                }
              : () => widget.onTaskTap?.call(task),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.only(left: depth * 20.0, top: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tree connector
                _buildTreeConnector(context, isLast, depth),
                // Status icon
                _buildStatusIcon(context, task.status),
                const SizedBox(width: 8),
                // Task content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              task.description,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontWeight:
                                        task.status ==
                                            AgentTaskStatus.inProgress
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    decoration:
                                        task.status == AgentTaskStatus.completed
                                        ? TextDecoration.none
                                        : null,
                                  ),
                            ),
                          ),
                          if (hasChildren)
                            Icon(
                              isExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 16,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                        ],
                      ),
                      // Tools chips
                      if (task.toolNames.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 2,
                            children: task.toolNames
                                .map((tool) => _buildToolChip(context, tool))
                                .toList(),
                          ),
                        ),
                      // Condensed summary (for completed tasks)
                      if (task.status == AgentTaskStatus.completed &&
                          task.condensedSummary != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '📝 ${_truncate(task.condensedSummary!, 100)}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontStyle: FontStyle.italic,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      // Findings button (for tasks with extracted findings)
                      if (task.status == AgentTaskStatus.completed &&
                          task.structuredFindings != null &&
                          task.structuredFindings!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: InkWell(
                            onTap: () => _showFindingsDialog(context, task),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.analytics_outlined,
                                    size: 14,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onTertiaryContainer,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${task.structuredFindings!.length} findings',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onTertiaryContainer,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // Error message
                      if (task.status == AgentTaskStatus.failed &&
                          task.result != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '❌ ${task.result}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                  ),
                            ),
                          ),
                        ),
                      // Paused task controls (turn limit exceeded)
                      if (task.status == AgentTaskStatus.paused)
                        _buildPausedTaskControls(context, task, agentService),
                      // Execution log preview (for active task)
                      if (task.status == AgentTaskStatus.inProgress &&
                          contextNode != null)
                        _buildExecutionLogPreview(context, contextNode),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // Children (if expanded)
        if (hasChildren && isExpanded)
          for (int i = 0; i < children.length; i++)
            _buildTaskNode(
              context,
              children[i],
              tasksByParent,
              agentService,
              isLast: i == children.length - 1,
              depth: depth + 1,
            ),
      ],
    );
  }

  Widget _buildTreeConnector(BuildContext context, bool isLast, int depth) {
    if (depth == 0) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(
          isLast ? '└─' : '├─',
          style: TextStyle(
            fontFamily: 'monospace',
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(
        isLast ? '└─' : '├─',
        style: TextStyle(
          fontFamily: 'monospace',
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }

  Widget _buildStatusIcon(BuildContext context, AgentTaskStatus status) {
    switch (status) {
      case AgentTaskStatus.pending:
        return Icon(
          Icons.radio_button_unchecked,
          size: 18,
          color: Theme.of(context).colorScheme.outline,
        );
      case AgentTaskStatus.inProgress:
        return AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Icon(
              Icons.play_circle,
              size: 18,
              color: Color.lerp(
                Theme.of(context).colorScheme.primary,
                Theme.of(context).colorScheme.tertiary,
                _pulseController.value,
              ),
            );
          },
        );
      case AgentTaskStatus.completed:
        return Icon(
          Icons.check_circle,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        );
      case AgentTaskStatus.failed:
        return Icon(
          Icons.error,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        );
      case AgentTaskStatus.paused:
        return Icon(
          Icons.pause_circle,
          size: 18,
          color: Theme.of(context).colorScheme.tertiary,
        );
    }
  }

  Widget _buildToolChip(BuildContext context, String toolName) {
    IconData icon;
    if (toolName.contains('search')) {
      icon = Icons.search;
    } else if (toolName.contains('read')) {
      icon = Icons.menu_book;
    } else if (toolName.contains('sql') || toolName.contains('query')) {
      icon = Icons.storage;
    } else if (toolName.contains('modify') || toolName.contains('write')) {
      icon = Icons.edit;
    } else {
      icon = Icons.build;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12),
          const SizedBox(width: 4),
          Text(
            toolName,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExecutionLogPreview(BuildContext context, ContextNode node) {
    final recentLogs = node.executionLog.length > 3
        ? node.executionLog.sublist(node.executionLog.length - 3)
        : node.executionLog;

    if (recentLogs.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  'Execution Log',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  '${node.estimatedTokens} tokens',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ...recentLogs.map(
              (log) => Text(
                _truncate(log, 80),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentThought(BuildContext context, String thought) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Color.lerp(
                Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
                Theme.of(context).colorScheme.primaryContainer.withOpacity(0.6),
                _pulseController.value,
              ),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.psychology,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    thought,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPausedTaskControls(
    BuildContext context,
    AgentTask task,
    AgentService agentService,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.tertiary),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    task.result ?? 'Max turns reached',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => agentService.abortTask(task.id),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.error,
                      ),
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    child: const Text('Abort', style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: FilledButton(
                    onPressed: () =>
                        agentService.resumeTask(task.id, increaseLimit: true),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                    ),
                    child: const Text(
                      '+10 Turns',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => agentService.concludeTask(task.id),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                    ),
                    child: const Text('Bail', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showFindingsDialog(BuildContext context, AgentTask task) {
    final findings = task.structuredFindings ?? [];
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.analytics_outlined,
              color: Theme.of(dialogContext).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Extracted Findings (${findings.length})',
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: MediaQuery.of(dialogContext).size.width * 0.8,
          height: MediaQuery.of(dialogContext).size.height * 0.6,
          child: findings.isEmpty
              ? const Center(child: Text('No findings extracted.'))
              : ListView.separated(
                  itemCount: findings.length,
                  separatorBuilder: (_, __) => const Divider(height: 16),
                  itemBuilder: (listContext, index) {
                    final f = findings[index];
                    final fact = f['fact'] ?? '';
                    final source = f['source'] ?? '';
                    final url = f['url'] ?? '';

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${index + 1}. $fact',
                          style: Theme.of(listContext).textTheme.bodyMedium,
                        ),
                        if (source.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              url.isNotEmpty
                                  ? 'Source: $source ($url)'
                                  : 'Source: $source',
                              style: Theme.of(listContext).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      listContext,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _saveFindings(task);
            },
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save Findings'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatFindingsAsMarkdown(AgentTask task) {
    final findings = task.structuredFindings ?? [];
    if (findings.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('## Research Findings');
    buffer.writeln();
    buffer.writeln('Task: ${task.description}');
    buffer.writeln();

    for (int i = 0; i < findings.length; i++) {
      final f = findings[i];
      final fact = f['fact'] ?? '';
      final source = f['source'] ?? '';
      final url = f['url'] ?? '';

      buffer.writeln('${i + 1}. **$fact**');
      if (source.isNotEmpty) {
        buffer.writeln('   - Source: $source');
      }
      if (url.isNotEmpty) {
        buffer.writeln('   - URL: $url');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  Future<void> _saveFindings(AgentTask task) async {
    if (!mounted) return;

    final content = _formatFindingsAsMarkdown(task);
    if (content.isEmpty) return;

    // Use the AddNoteDialog to let user choose create new or append
    await AddNoteDialog.show(context: context, content: content);
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }
}
