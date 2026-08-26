// Step 15 — `search_figures` must actually reach a chat/agent session.
//
// Both chat surfaces (conversation_chat_screen's _buildActiveToolsMap and
// ChatToolSession.buildActiveToolsMap) advertise and execute system tools by
// NAME against AgentService.nativeTools, and the picker they select from is
// BuiltInToolsService.systemTools — so those two registrations are what make
// the tool available everywhere. This pins both.

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/built_in_tools_service.dart';
import 'package:note_synapse/services/tools/figure_tools.dart';

// Reuses the mocks generated for the AgentService binding test — building an
// AgentService needs four collaborators, none of which this test exercises.
import 'agent_service_binding_test.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('search_figures is registered as a native tool', () {
    final agentService = AgentService(
      MockContextManagerService(),
      MockModelSelector(),
      MockAIService(),
      MockDatabaseService(),
    );

    expect(
      agentService.nativeTools.map((tool) => tool.name),
      contains(FigureSearchTool().name),
    );
  });

  test('search_figures is selectable in the system tool picker', () {
    final entry = BuiltInToolsService.getSystemToolById(
      FigureSearchTool().name,
    );

    expect(entry, isNotNull);
    expect(entry!.name, 'Search Figures');
  });
}
