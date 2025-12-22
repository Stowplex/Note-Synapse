import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/agent_service.dart';
import '../models/agent_task.dart';
import '../services/mcp_service.dart';
import '../services/user_app_service.dart';
import '../models/user_app.dart';

class AgentPlanReviewWidget extends StatefulWidget {
  final VoidCallback onProceed;
  final Function(String)? onCopy;
  final Function(String)? onAddNote;

  const AgentPlanReviewWidget({
    super.key,
    required this.onProceed,
    this.onCopy,
    this.onAddNote,
  });

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
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller:
                                                _itemControllers[task.id],
                                            decoration: InputDecoration(
                                              hintText:
                                                  'Add comment/refinement...',
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
                                            onChanged: (value) {
                                              task.userComment = value;
                                            },
                                          ),
                                        ),
                                        if (task.status ==
                                            AgentTaskStatus.pending)
                                          IconButton(
                                            icon: Icon(
                                              Icons.build_circle_outlined,
                                              size: 16,
                                              color:
                                                  task.allowedTools.isNotEmpty
                                                  ? Theme.of(
                                                      context,
                                                    ).colorScheme.primary
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant
                                                        .withOpacity(0.5),
                                            ),
                                            tooltip: 'Configure Allowed Tools',
                                            constraints: const BoxConstraints(
                                              minWidth: 24,
                                              minHeight: 24,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                            ),
                                            onPressed: () {
                                              _showToolSelectionDialog(
                                                context,
                                                task,
                                                agentService,
                                              );
                                            },
                                          ),
                                      ],
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
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showToolSelectionDialog(
    BuildContext context,
    AgentTask task,
    AgentService agentService,
  ) async {
    // Show loading dialog first
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // 1. Fetch all tools
      final Map<String, String> fullToolMap = {}; // toolName -> serviceName

      // Native Tools
      for (final tool in agentService.nativeTools) {
        fullToolMap[tool.name] = 'Built-in';
      }

      // MCP Tools
      try {
        final endpoints = await McpService.getEndpoints();
        for (final endpoint in endpoints) {
          // Assume all endpoints in the list are enabled candidates.
          // Check for cached tools.
          try {
            final cache = await McpService.getCachedTools(endpoint.id);
            if (cache != null && cache.tools.isNotEmpty) {
              for (final tool in cache.tools) {
                fullToolMap[tool.name] =
                    endpoint.name; // Use friendly name 'name', not 'id'
              }
            } else {
              // Optionally trigger refresh if cache empty?
              // For now, skip to avoid slow UI.
              // We could check if endpoint.name suggests it should have tools.
            }
          } catch (e) {
            print('Failed to fetch tools for ${endpoint.name}: $e');
          }
        }
      } catch (e) {
        print('Failed to fetch MCP endpoints: $e');
      }

      // Local AI Tools
      try {
        final allApps = await UserAppService.getAllUserApps();
        final localTools = allApps
            .where((app) => app.type == UserAppType.aiTool)
            .toList();
        for (final tool in localTools) {
          fullToolMap[tool.name] = 'Local AI';
        }
      } catch (e) {
        print('Failed to fetch local tools: $e');
      }

      if (context.mounted) Navigator.of(context).pop(); // Dismiss loading

      // 2. Sort and Prepare List
      final allTools = fullToolMap.keys.toList()
        ..sort((a, b) {
          final serviceA = fullToolMap[a] ?? '';
          final serviceB = fullToolMap[b] ?? '';
          final serviceCompare = serviceA.compareTo(serviceB);
          if (serviceCompare != 0) return serviceCompare;
          return a.compareTo(b);
        });

      // 3. Show Selection Dialog
      final selectedTools = Set<String>.from(task.allowedTools);

      if (!context.mounted) return;

      await showDialog(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                title: const Text('Select Allowed Tools'),
                content: SizedBox(
                  width: double.maxFinite,
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      SwitchListTile(
                        title: const Text('Restrict Tools?'),
                        subtitle: const Text(
                          'If disabled, all active tools are allowed.',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: selectedTools.isNotEmpty,
                        onChanged: (value) {
                          setState(() {
                            if (!value) {
                              selectedTools.clear();
                            } else {
                              // When enabling, default to all available tools
                              selectedTools.addAll(allTools);
                            }
                          });
                        },
                      ),
                      const Divider(),
                      if (selectedTools.isNotEmpty)
                        ...allTools.map((toolName) {
                          final serviceName =
                              fullToolMap[toolName] ?? 'Unknown';
                          return CheckboxListTile(
                            title: RichText(
                              text: TextSpan(
                                style: Theme.of(context).textTheme.bodyMedium,
                                children: [
                                  TextSpan(
                                    text: '$serviceName: ',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  TextSpan(text: toolName),
                                ],
                              ),
                            ),
                            value: selectedTools.contains(toolName),
                            onChanged: (value) {
                              setState(() {
                                if (value == true) {
                                  selectedTools.add(toolName);
                                } else {
                                  selectedTools.remove(toolName);
                                }
                              });
                            },
                          );
                        }),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      task.allowedTools = selectedTools.toList();
                      Navigator.of(context).pop(true);
                    },
                    child: const Text('Save'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (mounted) setState(() {});
    } catch (e) {
      print('Error showing tool selection: $e');
      if (context.mounted) {
        // Fallback or ensure dialog popped?
        // If we are here, likely something catastrophic happened before loading pop.
        // We just print error for now.
      }
    }
  }
}
