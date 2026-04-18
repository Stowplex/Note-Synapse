import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/built_in_tools_service.dart';

void main() {
  group('BuiltInTool', () {
    test('constructor creates tool with required properties', () {
      const tool = BuiltInTool(
        id: 'test_tool',
        name: 'Test Tool',
        description: 'A test tool description',
        icon: Icons.build,
      );

      expect(tool.id, equals('test_tool'));
      expect(tool.name, equals('Test Tool'));
      expect(tool.description, equals('A test tool description'));
      expect(tool.icon, equals(Icons.build));
      expect(tool.color, isNull);
    });

    test('constructor creates tool with optional color', () {
      const tool = BuiltInTool(
        id: 'colored_tool',
        name: 'Colored Tool',
        description: 'A tool with color',
        icon: Icons.palette,
        color: Colors.blue,
      );

      expect(tool.color, equals(Colors.blue));
    });
  });

  group('BuiltInToolsService - Constants', () {
    test('builtInEndpointId has expected value', () {
      expect(BuiltInToolsService.builtInEndpointId, equals('builtin_tools'));
    });

    test('agentToolId has expected value', () {
      expect(BuiltInToolsService.agentToolId, equals('agent_task_planner'));
    });

    test('systemToolsServiceKey has expected value', () {
      expect(BuiltInToolsService.systemToolsServiceKey, equals('System'));
    });
  });

  group('BuiltInToolsService - tools', () {
    test('tools list is not empty', () {
      final tools = BuiltInToolsService.tools;
      expect(tools, isNotEmpty);
    });

    test('tools list is unmodifiable', () {
      final tools = BuiltInToolsService.tools;
      expect(
        () => tools.add(
          const BuiltInTool(
            id: 'new',
            name: 'New',
            description: 'desc',
            icon: Icons.add,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('agent tool is in tools list', () {
      final tools = BuiltInToolsService.tools;
      final agentTool = tools
          .where((t) => t.id == BuiltInToolsService.agentToolId)
          .toList();
      expect(agentTool.length, equals(1));
      expect(agentTool.first.name, equals('Agent'));
    });
  });

  group('BuiltInToolsService - systemTools', () {
    test('systemTools list is not empty', () {
      final tools = BuiltInToolsService.systemTools;
      expect(tools, isNotEmpty);
    });

    test('systemTools list is unmodifiable', () {
      final tools = BuiltInToolsService.systemTools;
      expect(
        () => tools.add(
          const BuiltInTool(
            id: 'new',
            name: 'New',
            description: 'desc',
            icon: Icons.add,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('systemTools contains expected tools', () {
      final tools = BuiltInToolsService.systemTools;
      final toolIds = tools.map((t) => t.id).toList();

      expect(toolIds, contains('search_notes'));
      expect(toolIds, contains('read_note'));
      expect(toolIds, contains('run_sql'));
      expect(toolIds, contains('ls'));
      expect(toolIds, contains('modify_note'));
      expect(toolIds, contains('modify_notes'));
      expect(toolIds, contains('create_notes'));
      expect(toolIds, contains('delete_notes'));
    });

    test('search_notes tool has correct properties', () {
      final tool = BuiltInToolsService.systemTools.firstWhere(
        (t) => t.id == 'search_notes',
      );
      expect(tool.name, equals('Search Notes'));
      expect(tool.icon, equals(Icons.search));
      expect(tool.color, equals(Colors.blue));
    });

    test('delete_notes tool has correct properties', () {
      final tool = BuiltInToolsService.systemTools.firstWhere(
        (t) => t.id == 'delete_notes',
      );
      expect(tool.name, equals('Delete Note'));
      expect(tool.icon, equals(Icons.delete_outline));
      expect(tool.color, equals(Colors.red));
    });
  });

  group('BuiltInToolsService - getToolById', () {
    test('returns tool when id exists', () {
      final tool = BuiltInToolsService.getToolById(
        BuiltInToolsService.agentToolId,
      );
      expect(tool, isNotNull);
      expect(tool!.id, equals(BuiltInToolsService.agentToolId));
    });

    test('returns null when id does not exist', () {
      final tool = BuiltInToolsService.getToolById('nonexistent_tool');
      expect(tool, isNull);
    });
  });

  group('BuiltInToolsService - getSystemToolById', () {
    test('returns system tool when id exists', () {
      final tool = BuiltInToolsService.getSystemToolById('search_notes');
      expect(tool, isNotNull);
      expect(tool!.id, equals('search_notes'));
      expect(tool.name, equals('Search Notes'));
    });

    test('returns null when id does not exist', () {
      final tool = BuiltInToolsService.getSystemToolById('nonexistent_tool');
      expect(tool, isNull);
    });

    test('returns null for agent tool id (not in system tools)', () {
      final tool = BuiltInToolsService.getSystemToolById(
        BuiltInToolsService.agentToolId,
      );
      expect(tool, isNull);
    });

    test('finds all system tools by id', () {
      final expectedIds = [
        'search_notes',
        'read_note',
        'run_sql',
        'ls',
        'modify_note',
        'modify_notes',
        'create_notes',
        'delete_notes',
      ];

      for (final id in expectedIds) {
        final tool = BuiltInToolsService.getSystemToolById(id);
        expect(tool, isNotNull, reason: 'Tool $id should exist');
        expect(tool!.id, equals(id));
      }
    });
  });
}
