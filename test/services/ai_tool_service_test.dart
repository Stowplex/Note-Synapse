import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/app_revision.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/ai_tool_service.dart';

void main() {
  group('AiToolService', () {
    test('loadAppBundle correctly dedents YAML in tool_spec', () async {
      // Setup
      final app = UserApp(
        id: 'test-id',
        uuid: 'test-uuid',
        name: 'Test Tool',
        description: 'Test Description',
        steps: const [],
        htmlContent: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final indentedHtml = '''
<html>
  <script>
    <![CDATA[tool_spec
      - name: indented_tool
        description: |
          This is a description
          that spans multiple lines
          and is indented.
        input_params:
          - param1: string
    ]]>
  </script>
</html>
''';

      final revision = AppRevision(
        id: 'rev-uuid',
        appId: app.id,
        revisionNumber: 1,
        revisionTimestamp: DateTime.now(),
        userPrompt: '',
        aiResponse: '',
        appCode: indentedHtml,
      );

      // Act
      final bundle = await AiToolService.loadAppBundle(
        app: app,
        revision: revision,
      );

      // Assert
      expect(bundle, isNotNull);
      expect(bundle!.toolDefinitions.length, 1);
      final tool = bundle.toolDefinitions.first;
      expect(tool.toolName, 'indented_tool');
      expect(
        tool.description,
        contains(
          'This is a description\nthat spans multiple lines\nand is indented.',
        ),
      );
    });

    test('loadAppBundle handles minimal indentation', () async {
      final app = UserApp(
        id: 'test-id-2',
        uuid: 'test-uuid-2',
        name: 'Test Tool 2',
        description: 'Test Description 2',
        steps: const [],
        htmlContent: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final html = '''
<![CDATA[tool_spec
- name: tool2
  description: simple
]]>
''';
      final revision = AppRevision(
        id: 'rev-uuid-2',
        appId: app.id,
        revisionNumber: 1,
        revisionTimestamp: DateTime.now(),
        userPrompt: '',
        aiResponse: '',
        appCode: html,
      );

      final bundle = await AiToolService.loadAppBundle(
        app: app,
        revision: revision,
      );

      expect(bundle, isNotNull);
      expect(bundle!.toolDefinitions.first.toolName, 'tool2');
    });
  });
}
