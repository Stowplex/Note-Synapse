import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/approval_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/sql_query_service.dart';
import 'package:note_synapse/services/tools/load_skill_tool.dart';
import 'package:note_synapse/services/tools/note_tools.dart';
import 'package:note_synapse/services/tools/read_task_result_tool.dart';
import 'package:note_synapse/services/tools/tool_outcome.dart';
import 'package:note_synapse/services/tools/tool_param_validator.dart';

@GenerateMocks([
  ContextManagerService,
  ModelSelector,
  AIService,
  DatabaseService,
  NoteModificationService,
  SqlQueryService,
])
import 'tool_error_leak_test.mocks.dart';

/// Fuzz sweep: no native tool may ever leak a raw Dart type-cast error
/// ("is not a subtype of") to the model, no matter how malformed the
/// arguments are. Probes replay the failure classes observed in real traces
/// (scalar-for-object, "Infinity", null, wrong containers) into every
/// declared parameter path, including nested ones — the original bug lived
/// at depth 2 (`modifications[0].modification`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const probes = <dynamic>[4, 'Infinity', null, <dynamic>[], <dynamic>[4], <String, dynamic>{}];

  final tools = <NativeTool>[
    NoteSearchTool(),
    NoteReadTool(),
    RunSqlTool(),
    ListFiltersTool(),
    ModifyNoteTool(),
    ModifyNotesTool(),
    CreateNotesTool(),
    DeleteNoteTool(),
    LoadSkillTool(),
    ReadTaskResultTool(MockContextManagerService()),
  ];

  setUp(() async {
    await resetForTesting();
    final mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<NoteModificationService>(
      MockNoteModificationService(),
    );
    getIt.registerSingleton<SqlQueryService>(MockSqlQueryService());
    getIt.registerSingleton<SkillService>(SkillService(mockDb));
    getIt.registerSingleton<ContextManagerService>(MockContextManagerService());
    // Auto-decline approvals: fuzzing must trigger neither UI nor writes.
    ApprovalService.resetSession();
    ApprovalService.onApprovalRequest = (_) async =>
        ApprovalResult(approved: false);
  });

  tearDown(() async {
    ApprovalService.onApprovalRequest = null;
    await resetForTesting();
  });

  /// Simulates the dispatch boundary: validator first, then execution with
  /// exception normalization — mirroring chat_tool_session/agent dispatch.
  Future<String> dispatchLikeBoundary(
    NativeTool tool,
    Map<String, dynamic> args,
  ) async {
    final invalid = ToolParamValidator.validationFailure(
      toolName: tool.name,
      params: args,
      inputSchema: tool.inputSchema,
    );
    if (invalid != null) return invalid.serialize();
    try {
      final result = await tool.execute(args);
      return ToolOutcome.fromNativeResult(tool.name, result).serialize();
    } catch (e) {
      return ToolOutcome.fromException(tool.name, e).serialize();
    }
  }

  /// All argument maps to probe for one tool: each top-level property, plus
  /// one nesting level through object `properties` and array `items`.
  List<Map<String, dynamic>> buildProbeArgs(Map<String, dynamic> schema) {
    final argsList = <Map<String, dynamic>>[];
    final properties = (schema['properties'] as Map?) ?? const {};
    for (final entry in properties.entries) {
      final name = entry.key.toString();
      final propSchema = entry.value is Map ? entry.value as Map : const {};
      for (final probe in probes) {
        argsList.add({name: probe});
      }
      final nestedProps = propSchema['properties'];
      if (nestedProps is Map) {
        for (final nested in nestedProps.keys) {
          for (final probe in probes) {
            argsList.add({
              name: {nested.toString(): probe},
            });
          }
        }
      }
      final items = propSchema['items'];
      if (items is Map) {
        for (final probe in probes) {
          argsList.add({
            name: [probe],
          });
        }
        final itemProps = items['properties'];
        if (itemProps is Map) {
          for (final nested in itemProps.keys) {
            for (final probe in probes) {
              argsList.add({
                name: [
                  {nested.toString(): probe},
                ],
              });
            }
          }
        }
      }
    }
    // The observed trace payloads, verbatim, when the tool has the fields.
    if (properties.containsKey('modifications')) {
      argsList.add({
        'modifications': [
          {'note_id': 'cc1cf667', 'modification': 4},
        ],
      });
      argsList.add({
        'modifications': [
          {'note_id': 'cc1cf667', 'modification': 'Infinity'},
        ],
      });
    }
    if (properties.containsKey('modification')) {
      argsList.add({
        'modification': {'content': null, 'tags': null},
      });
    }
    return argsList;
  }

  test('no native tool leaks raw type-cast errors for malformed args', () async {
    final leaks = <String>[];
    for (final tool in tools) {
      for (final args in buildProbeArgs(tool.inputSchema)) {
        final response = await dispatchLikeBoundary(tool, args);
        if (response.contains('is not a subtype')) {
          leaks.add('${tool.name} <- $args -> $response');
        }
      }
    }
    expect(
      leaks,
      isEmpty,
      reason:
          'Raw Dart cast errors reached the tool boundary:\n${leaks.join('\n')}',
    );
  });

  test('fuzzed tool set matches the AgentService native tool registry '
      '(drift guard)', () {
    final agentService = AgentService(
      MockContextManagerService(),
      MockModelSelector(),
      MockAIService(),
      MockDatabaseService(),
    );
    expect(
      tools.map((tool) => tool.name).toSet(),
      agentService.nativeTools.map((tool) => tool.name).toSet(),
      reason:
          'A native tool was added or removed; update the fuzz sweep list.',
    );
  });
}
