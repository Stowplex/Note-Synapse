import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/mcp_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

import 'conversation_skill_discovery_test.mocks.dart';

@GenerateMocks([DatabaseService, AgentService, SkillService, McpService])
void main() {
  late MockDatabaseService mockDb;
  late MockAgentService mockAgentService;
  late MockSkillService mockSkillService;
  late MockMcpService mockMcpService;
  late ConversationService svc;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockAgentService = MockAgentService();
    mockSkillService = MockSkillService();
    mockMcpService = MockMcpService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<AgentService>(mockAgentService);
    getIt.registerSingleton<SkillService>(mockSkillService);
    getIt.registerSingleton<McpService>(mockMcpService);
    svc = ConversationService.createForTesting(mockDb);
  });

  group('enableSkills', () {
    test('populates skill index from DB', () async {
      const noteId = 'note-abc';
      final expectedIndex = {
        noteId: SkillMetadata(
          noteId: noteId,
          skillRef: 'my-skill',
          name: 'My Skill',
          description: 'Does something useful',
          enabled: true,
        ),
      };
      when(
        mockSkillService.buildSkillIndex(),
      ).thenAnswer((_) async => expectedIndex);

      await svc.enableSkills();

      verify(mockSkillService.buildSkillIndex()).called(1);
      expect(svc.skillsEnabled, isTrue);
      expect(svc.skillIndex, equals(expectedIndex));
    });
  });

  group('disableSkills', () {
    test('clears index and discovered tools', () async {
      // Set up: enable skills so there is state to clear.
      when(mockSkillService.buildSkillIndex()).thenAnswer(
        (_) async => {
          'note-1': SkillMetadata(
            noteId: 'note-1',
            skillRef: 'skill-a',
            name: 'Skill A',
            description: 'desc',
            enabled: true,
          ),
        },
      );
      await svc.enableSkills();
      expect(svc.skillsEnabled, isTrue);
      expect(svc.skillIndex, isNotEmpty);

      // Also discover a tool to ensure that list is cleared too.
      const uri = 'notesynapse://tool/builtin/search_notes';
      when(mockSkillService.extractToolUris(any)).thenReturn([uri]);
      when(
        mockSkillService.parseToolUri(uri),
      ).thenReturn((namespace: 'builtin', id: 'search_notes', function: null));
      when(mockAgentService.nativeTools).thenReturn([NoteSearchTool()]);
      await svc.handleLoadSkillResult('note-1', 'content');
      expect(svc.skillDiscoveredTools, isNotEmpty);

      // Act: disable.
      svc.disableSkills();

      expect(svc.skillsEnabled, isFalse);
      expect(svc.skillIndex, isEmpty);
      expect(svc.skillDiscoveredTools, isEmpty);
      expect(svc.skillDiscoveredNativeToolNames, isEmpty);
      expect(svc.skillToolEndpointNames, isEmpty);
      expect(svc.skillToolEndpointIds, isEmpty);
      expect(svc.skillDiscoveredBundles, isEmpty);
    });
  });

  group('handleLoadSkillResult', () {
    test('discovers builtin tool URIs from skill content', () async {
      when(mockSkillService.buildSkillIndex()).thenAnswer((_) async => {});
      await svc.enableSkills();

      const uri = 'notesynapse://tool/builtin/search_notes';
      when(mockSkillService.extractToolUris(any)).thenReturn([uri]);
      when(
        mockSkillService.parseToolUri(uri),
      ).thenReturn((namespace: 'builtin', id: 'search_notes', function: null));
      when(mockAgentService.nativeTools).thenReturn([NoteSearchTool()]);

      await svc.handleLoadSkillResult('note-1', 'skill content with tool URI');

      expect(svc.skillDiscoveredTools.length, equals(1));
      expect(svc.skillDiscoveredTools.first.name, equals('search_notes'));
      expect(svc.skillDiscoveredNativeToolNames, contains('search_notes'));
    });

    test(
      'second enableSkills resets state cleanly (no duplicate tools)',
      () async {
        when(mockSkillService.buildSkillIndex()).thenAnswer((_) async => {});
        await svc.enableSkills();

        const uri = 'notesynapse://tool/builtin/search_notes';
        when(mockSkillService.extractToolUris(any)).thenReturn([uri]);
        when(mockSkillService.parseToolUri(uri)).thenReturn((
          namespace: 'builtin',
          id: 'search_notes',
          function: null,
        ));
        when(mockAgentService.nativeTools).thenReturn([NoteSearchTool()]);

        // Discover tools in the first session.
        await svc.handleLoadSkillResult('note-1', 'skill content');
        expect(svc.skillDiscoveredTools.length, equals(1));

        // Start a second session via enableSkills().
        await svc.enableSkills();

        // The previously discovered tools must be gone — state resets.
        expect(svc.skillDiscoveredTools, isEmpty);
        expect(svc.skillDiscoveredNativeToolNames, isEmpty);

        // Rediscovering the same tool should add it exactly once.
        await svc.handleLoadSkillResult('note-1', 'skill content');
        expect(svc.skillDiscoveredTools.length, equals(1));
      },
    );
  });
}
