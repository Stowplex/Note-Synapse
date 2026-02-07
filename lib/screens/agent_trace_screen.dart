import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/agent_trace_view.dart';
import '../services/agent_service.dart';

class AgentTraceScreen extends StatelessWidget {
  const AgentTraceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent Progress'),
        actions: [
          Consumer<AgentService>(
            builder: (context, agent, _) {
              if (agent.isRunning) {
                return IconButton(
                  icon: const Icon(Icons.stop),
                  onPressed: () => agent.cancel(),
                  tooltip: 'Stop Agent',
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      body: const AgentTraceView(),
    );
  }
}
