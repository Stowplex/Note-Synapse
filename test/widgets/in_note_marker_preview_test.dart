import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/in_note_marker_preview.dart';

import 'in_note_marker_preview_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    // Annotation path's _loadData() still runs and reads the database.
    // Stub the calls it makes so the loading state resolves cleanly.
    when(mockDb.getConversationMessage(any)).thenAnswer((_) async => null);
    when(mockDb.getConversationMessages(any)).thenAnswer((_) async => const <ConversationMessage>[]);
    getIt.registerSingleton<DatabaseService>(mockDb);
  });

  tearDown(() async {
    await resetForTesting();
  });

  testWidgets('annotation marker uses the legacy preview path', (tester) async {
    final m = InNoteMarker.forNote(
      index: 0,
      charStart: 0,
      charEnd: 5,
      conversationId: 'c',
      messageId: 'm',
      type: MarkerType.annotation,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: InNoteMarkerPreview(marker: m)),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('legacy-annotation-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-marker-chat-panel-host')), findsNothing);
  });

  testWidgets('AI marker uses the ChatPanel-hosted path', (tester) async {
    final m = InNoteMarker.forNote(
      index: 0,
      charStart: 0,
      charEnd: 5,
      conversationId: 'c',
      messageId: 'm',
      // type defaults to MarkerType.ai
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: InNoteMarkerPreview(marker: m)),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-marker-chat-panel-host')), findsOneWidget);
    expect(find.byKey(const ValueKey('legacy-annotation-preview')), findsNothing);
  });
}
