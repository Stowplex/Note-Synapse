import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/built_in_tools_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/sql_query_service.dart';
import 'package:note_synapse/services/service_locator.dart';

// Mocks
class MockContextManagerService extends Mock implements ContextManagerService {}

class MockModelSelector extends Mock implements ModelSelector {}

class MockAIService extends Mock implements AIService {}

class MockDatabaseService extends Mock implements DatabaseService {}

class MockNoteModificationService extends Mock
    implements NoteModificationService {}

class MockSqlQueryService extends Mock implements SqlQueryService {}

void main() {
  late AgentService agentService;
  late MockContextManagerService mockContextManager;
  late MockModelSelector mockModelSelector;
  late MockAIService mockAIService;
  late MockDatabaseService mockDatabaseService;
  late MockNoteModificationService mockNoteModificationService;
  late MockSqlQueryService mockSqlQueryService;

  setUp(() {
    mockContextManager = MockContextManagerService();
    mockModelSelector = MockModelSelector();
    mockAIService = MockAIService();
    mockDatabaseService = MockDatabaseService();
    mockNoteModificationService = MockNoteModificationService();
    mockSqlQueryService = MockSqlQueryService();

    // Register mocks in GetIt for tools that need them
    if (getIt.isRegistered<DatabaseService>()) {
      getIt.unregister<DatabaseService>();
    }
    getIt.registerSingleton<DatabaseService>(mockDatabaseService);

    if (getIt.isRegistered<NoteModificationService>()) {
      getIt.unregister<NoteModificationService>();
    }
    getIt.registerSingleton<NoteModificationService>(
      mockNoteModificationService,
    );

    if (getIt.isRegistered<SqlQueryService>()) {
      getIt.unregister<SqlQueryService>();
    }
    getIt.registerSingleton<SqlQueryService>(mockSqlQueryService);

    if (getIt.isRegistered<AIService>()) {
      getIt.unregister<AIService>();
    }
    getIt.registerSingleton<AIService>(mockAIService);

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDatabaseService,
    );
  });

  tearDown(() {
    getIt.reset();
  });

  test('All system tool IDs should exist in AgentService native tools', () {
    final systemTools = BuiltInToolsService.systemTools;
    final nativeTools = agentService.nativeTools;

    // Create a map of native tools for O(1) lookup
    final nativeToolNames = nativeTools.map((t) => t.name).toSet();

    final missingTools = <String>[];

    for (final tool in systemTools) {
      if (!nativeToolNames.contains(tool.id)) {
        missingTools.add(tool.id);
      }
    }

    if (missingTools.isNotEmpty) {
      fail(
        'The following system tool IDs are missing from AgentService native tools: ${missingTools.join(', ')}. '
        'This causes these tools to be filtered out when enabled in the UI.',
      );
    }
  });
}
