import '../context_manager_service.dart';
import 'note_tools.dart';

/// Tool for lazy-loading task result sections.
///
/// Enables LLM to fetch full details from ancestor tasks when the context
/// only shows a TOC (table of contents) preview.
class ReadTaskResultTool implements NativeTool {
  final ContextManagerService _contextManager;

  ReadTaskResultTool(this._contextManager);

  @override
  String get name => 'read_task_result';

  @override
  String get description => '''
Read result content from a previous task. Use this when ancestor task results 
show a TOC preview and you need the full content or a specific section.

Modes:
- 'full': Returns the complete task result
- 'section': Returns a specific section by breadcrumb path

Example calls:
- {"task_id": "abc123", "mode": "full"}
- {"task_id": "abc123", "mode": "section", "section": "# Findings > ## Key Data"}
''';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'task_id': {
        'type': 'string',
        'description': 'ID of the ancestor task to read from',
      },
      'mode': {
        'type': 'string',
        'enum': ['full', 'section'],
        'description': 'full = complete result, section = specific section',
        'default': 'full',
      },
      'section': {
        'type': 'string',
        'description': 'Breadcrumb path to section (required for mode=section)',
      },
    },
    'required': ['task_id'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final taskId = args['task_id'] as String?;
    if (taskId == null || taskId.isEmpty) {
      return 'Error: task_id is required';
    }

    final mode = args['mode'] as String? ?? 'full';
    final sectionPath = args['section'] as String?;

    final node = _contextManager.getContext(taskId);
    if (node == null) {
      return 'Error: No task found with ID "$taskId"';
    }

    final result = node.structuredResult;
    if (result == null) {
      // Fallback: return summary or log
      if (node.summary != null) {
        return 'Task result (summary):\n${node.summary}';
      }
      return 'Task result (execution log):\n${node.executionLog.join('\n')}';
    }

    if (mode == 'full') {
      return result.fullResult;
    } else if (mode == 'section') {
      if (sectionPath == null || sectionPath.isEmpty) {
        return 'Error: section parameter required for mode=section. Available sections:\n${result.toc}';
      }

      final section = result.findSection(sectionPath);
      if (section == null) {
        return 'Error: Section not found: "$sectionPath".\nAvailable sections:\n${result.toc}';
      }

      return section.getContent(result.fullResult);
    }

    return 'Error: Invalid mode "$mode". Use "full" or "section".';
  }
}
