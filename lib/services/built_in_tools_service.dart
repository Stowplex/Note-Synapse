import 'package:flutter/material.dart';

/// Represents a built-in tool that behaves like an MCP tool but runs locally
class BuiltInTool {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final Color? color;

  const BuiltInTool({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.color,
  });
}

/// Service to manage available built-in tools
class BuiltInToolsService {
  static const String builtInEndpointId = 'builtin_tools';
  static const String agentToolId = 'agent_task_planner';

  static final List<BuiltInTool> _tools = [
    const BuiltInTool(
      id: agentToolId,
      name: 'Agent',
      description:
          'Autonomous agent that can plan and execute complex tasks using multiple tools.',
      icon: Icons.psychology, // Or auto_mode, smart_toy
      color: Colors.purple, // Distinctive color
    ),
  ];

  static List<BuiltInTool> get tools => List.unmodifiable(_tools);

  static BuiltInTool? getToolById(String id) {
    try {
      return _tools.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }
}
