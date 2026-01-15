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

  /// Service key used for system tools in activeTools map
  static const String systemToolsServiceKey = 'System';

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

  /// System tools that map to AgentService.nativeTools
  /// These are displayed separately from the agent toggle
  static final List<BuiltInTool> _systemTools = [
    const BuiltInTool(
      id: 'search_notes',
      name: 'Search Notes',
      description:
          'Search for notes using full-text search with optional tag filtering.',
      icon: Icons.search,
      color: Colors.blue,
    ),
    const BuiltInTool(
      id: 'read_note',
      name: 'Read Note',
      description:
          'Read note content with progressive discovery modes (stat, lines, summary, etc.).',
      icon: Icons.article_outlined,
      color: Colors.green,
    ),
    const BuiltInTool(
      id: 'run_sql',
      name: 'Run SQL',
      description:
          'Execute SQL queries on the local database. Write operations require approval.',
      icon: Icons.storage,
      color: Colors.orange,
    ),
    const BuiltInTool(
      id: 'ls',
      name: 'List Filters',
      description: 'List all tag filters (folders) in a tree structure.',
      icon: Icons.folder_outlined,
      color: Colors.teal,
    ),
    const BuiltInTool(
      id: 'modify_note',
      name: 'Modify Note',
      description:
          'Modify note content, title, tags, or attachments. Requires approval.',
      icon: Icons.edit_note,
      color: Colors.amber,
    ),
    const BuiltInTool(
      id: 'create_note',
      name: 'Create Note',
      description:
          'Create new notes with content, tags, and attachments. Requires approval.',
      icon: Icons.note_add,
      color: Colors.indigo,
    ),
    const BuiltInTool(
      id: 'delete_note',
      name: 'Delete Note',
      description: 'Delete notes by ID. Requires approval.',
      icon: Icons.delete_outline,
      color: Colors.red,
    ),
  ];

  static List<BuiltInTool> get tools => List.unmodifiable(_tools);

  /// Get system tool definitions for UI display
  static List<BuiltInTool> get systemTools => List.unmodifiable(_systemTools);

  static BuiltInTool? getToolById(String id) {
    try {
      return _tools.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Get a system tool by its ID (tool name)
  static BuiltInTool? getSystemToolById(String id) {
    try {
      return _systemTools.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }
}
