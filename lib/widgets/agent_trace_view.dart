import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/agent_service.dart';
import '../models/agent_task.dart';

class AgentTraceView extends StatelessWidget {
  const AgentTraceView({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AgentService>(
      builder: (context, agent, child) {
        if (!agent.isRunning && agent.tasks.isEmpty) {
          return const Center(child: Text('No active agent task.'));
        }

        return Column(
          children: [
            if (agent.currentThought != null)
              Container(
                padding: const EdgeInsets.all(8),
                color: const Color(0xFF2196F3).withOpacity(0.1), // Blue
                child: Row(
                  children: [
                    const Icon(Icons.psychology, size: 16, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        agent.currentThought!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: agent.tasks.length,
                itemBuilder: (context, index) {
                  final task = agent.tasks[index];
                  return _buildTaskTile(context, task);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTaskTile(BuildContext context, AgentTask task) {
    IconData icon;
    Color color;

    switch (task.status) {
      case AgentTaskStatus.pending:
        icon = Icons.radio_button_unchecked;
        color = Colors.grey;
        break;
      case AgentTaskStatus.inProgress:
        icon = Icons.hourglass_top;
        color = Colors.blue;
        break;
      case AgentTaskStatus.completed:
        icon = Icons.check_circle;
        color = Colors.green;
        break;
      case AgentTaskStatus.failed:
        icon = Icons.error;
        color = Colors.red;
        break;
      case AgentTaskStatus.paused:
        icon = Icons.pause_circle_filled;
        color = Colors.orange;
        break;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        leading: task.status == AgentTaskStatus.inProgress
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, color: color),
        title: Text(
          task.description,
          style: TextStyle(
            decoration: task.status == AgentTaskStatus.completed
                ? TextDecoration.lineThrough
                : null,
            color: task.status == AgentTaskStatus.completed
                ? Colors.grey
                : null,
            fontWeight: task.status == AgentTaskStatus.inProgress
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        ),
        children: [
          if (task.result != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withOpacity(0.3),
              child: Text(
                task.result!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
