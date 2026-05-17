import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/models/note_annotation.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/fork_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/note_marker_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/fullscreen_image_preview.dart';
import 'package:note_synapse/widgets/in_note_annotation_preview.dart';
import 'package:note_synapse/widgets/in_note_marker_preview.dart';
import 'package:note_synapse/widgets/marker_chat_panel_host.dart';
import 'package:note_synapse/widgets/marker_orphan_state.dart';

import 'in_note_marker_preview_test.mocks.dart';

/// Test double for [NoteMarkerService] that records calls but never touches
/// the database. The widget calls [updateMarkerLastViewed] fire-and-forget
/// (e.g. to clear stale lastViewed pointers); we don't want those writes
/// to throw or wedge the test loop.
class _RecordingNoteMarkerService implements NoteMarkerService {
  final List<({String markerId, String? newConvId})> updates = [];
  final List<String> deletes = [];

  @override
  Future<void> updateMarkerLastViewed(
    String markerId,
    String? newConvId,
  ) async {
    updates.add((markerId: markerId, newConvId: newConvId));
  }

  @override
  Future<void> deleteMarker(String markerId) async {
    deletes.add(markerId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@GenerateMocks([
  DatabaseService,
  ConversationService,
  ForkService,
  ModelStorageService,
])
void main() {
  late MockDatabaseService mockDb;
  late MockConversationService mockConv;
  late MockForkService mockFork;
  late MockModelStorageService mockModelStorage;
  late _RecordingNoteMarkerService fakeMarkerService;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockConv = MockConversationService();
    mockFork = MockForkService();
    mockModelStorage = MockModelStorageService();
    fakeMarkerService = _RecordingNoteMarkerService();
    // Annotation path's _loadData() still runs and reads the database.
    // Stub the calls it makes so the loading state resolves cleanly.
    when(mockDb.getConversationMessage(any)).thenAnswer((_) async => null);
    when(
      mockDb.getConversationMessages(any),
    ).thenAnswer((_) async => const <ConversationMessage>[]);
    when(mockDb.getConversation(any)).thenAnswer((_) async => null);
    // AI-marker path uses ChatPanel, which depends on ConversationService and
    // ForkService; the embedded ModelSelectorButton needs ModelStorageService.
    when(mockFork.forkCreatedStream).thenAnswer((_) => const Stream.empty());
    when(
      mockModelStorage.getConfiguredModels(),
    ).thenAnswer((_) async => const []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);
    final now = DateTime.now();
    when(mockConv.getConversation(any)).thenAnswer(
      (_) async => Conversation(
        id: 'c',
        title: 'T',
        noteIds: const [],
        createdAt: now,
        updatedAt: now,
      ),
    );
    when(
      mockConv.getConversationMessages(any),
    ).thenAnswer((_) async => const []);
    when(
      mockConv.getAllForkPointBranches(any),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<ConversationService>(mockConv);
    getIt.registerSingleton<ForkService>(mockFork);
    getIt.registerSingleton<ModelStorageService>(mockModelStorage);
    getIt.registerSingleton<NoteMarkerService>(fakeMarkerService);
  });

  tearDown(() async {
    await resetForTesting();
  });

  ConversationMessage stubAnchorMessage({
    String content = 'hi',
    List<String> attachmentPaths = const [],
  }) => ConversationMessage(
    id: 'm',
    conversationId: 'c',
    type: MessageType.user,
    content: content,
    timestamp: DateTime.now(),
    attachmentPaths: attachmentPaths,
  );

  Conversation stubConversation(String id) {
    final now = DateTime.now();
    return Conversation(
      id: id,
      title: 'T',
      noteIds: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  File writeTempPng(String name) {
    final file = File(
      '${Directory.systemTemp.path}/note_synapse_${DateTime.now().microsecondsSinceEpoch}_$name.png',
    );
    file.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
      ),
    );
    return file;
  }

  testWidgets('annotation marker uses the legacy preview path', (tester) async {
    final m = InNoteMarker.forNote(
      index: 0,
      charStart: 0,
      charEnd: 5,
      conversationId: 'c',
      messageId: 'm',
      type: MarkerType.annotation,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InNoteMarkerPreview(marker: m)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('legacy-annotation-preview')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-marker-chat-panel-host')),
      findsNothing,
    );
  });

  testWidgets('AI marker with deleted anchor renders anchor-deleted orphan', (
    tester,
  ) async {
    // getConversationMessage already stubbed to null in setUp.
    final m = InNoteMarker.forNote(
      index: 0,
      charStart: 0,
      charEnd: 5,
      conversationId: 'c',
      messageId: 'm',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InNoteMarkerPreview(marker: m)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('ai-marker-chat-panel-host')),
      findsOneWidget,
    );
    expect(find.byType(MarkerOrphanState), findsOneWidget);
    expect(find.textContaining('anchor message'), findsOneWidget);
  });

  testWidgets(
    'AI marker with live anchor but missing conversation renders conversation-deleted orphan',
    (tester) async {
      when(
        mockDb.getConversationMessage(any),
      ).thenAnswer((_) async => stubAnchorMessage());
      when(mockDb.getConversation(any)).thenAnswer((_) async => null);
      final m = InNoteMarker.forNote(
        index: 0,
        charStart: 0,
        charEnd: 5,
        conversationId: 'c',
        messageId: 'm',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InNoteMarkerPreview(marker: m)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MarkerOrphanState), findsOneWidget);
      expect(
        find.textContaining('conversation no longer exists'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'AI marker happy path renders MarkerChatPanelHost on resolved conversation',
    (tester) async {
      when(
        mockDb.getConversationMessage(any),
      ).thenAnswer((_) async => stubAnchorMessage());
      when(
        mockDb.getConversation('c'),
      ).thenAnswer((_) async => stubConversation('c'));
      final m = InNoteMarker.forNote(
        index: 0,
        charStart: 0,
        charEnd: 5,
        conversationId: 'c',
        messageId: 'm',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InNoteMarkerPreview(marker: m)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MarkerChatPanelHost), findsOneWidget);
      expect(find.byType(MarkerOrphanState), findsNothing);
    },
  );

  testWidgets(
    'focus action persists last viewed, dismisses sheet, and reports target',
    (tester) async {
      when(
        mockDb.getConversationMessage(any),
      ).thenAnswer((_) async => stubAnchorMessage());
      when(
        mockDb.getConversation('c'),
      ).thenAnswer((_) async => stubConversation('c'));
      final m = InNoteMarker.forNote(
        id: 'marker-id',
        index: 0,
        charStart: 0,
        charEnd: 5,
        conversationId: 'c',
        messageId: 'm',
      );
      bool? result;
      String? focusedConversationId;
      String? focusedMessageId;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showInNoteMarkerPreview(
                    context,
                    m,
                    onFocusConversation: (conversationId, markerMessageId) {
                      focusedConversationId = conversationId;
                      focusedMessageId = markerMessageId;
                    },
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('focus-marker-conversation-button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('focus-marker-conversation-button')),
      );
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(focusedConversationId, 'c');
      expect(focusedMessageId, 'm');
      expect(fakeMarkerService.updates, isNotEmpty);
      expect(fakeMarkerService.updates.last.markerId, 'marker-id');
      expect(fakeMarkerService.updates.last.newConvId, 'c');
      expect(find.byType(MarkerChatPanelHost), findsNothing);
    },
  );

  testWidgets('AI marker context card image opens fullscreen preview', (
    tester,
  ) async {
    final imageFile = writeTempPng('ai_marker');
    when(mockDb.getConversationMessage(any)).thenAnswer(
      (_) async => stubAnchorMessage(
        content: 'Explain Fourier transforms using intuition.',
        attachmentPaths: [imageFile.path],
      ),
    );
    when(
      mockDb.getConversation('c'),
    ).thenAnswer((_) async => stubConversation('c'));
    final m = InNoteMarker.forNote(
      index: 2,
      charStart: 0,
      charEnd: 5,
      conversationId: 'c',
      messageId: 'm',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InNoteMarkerPreview(marker: m)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MarkerChatPanelHost), findsOneWidget);
    expect(find.text('Marker 2'), findsOneWidget);
    expect(find.text('Original prompt'), findsOneWidget);
    expect(
      find.text('Explain Fourier transforms using intuition.'),
      findsOneWidget,
    );
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenImagePreview), findsOneWidget);
    expect(find.text('Marker 2'), findsWidgets);
  });

  testWidgets('AI marker missing context image is not clickable', (
    tester,
  ) async {
    when(mockDb.getConversationMessage(any)).thenAnswer(
      (_) async => stubAnchorMessage(
        content: 'Explain Fourier transforms using intuition.',
        attachmentPaths: const ['/tmp/nonexistent-marker-context.png'],
      ),
    );
    when(
      mockDb.getConversation('c'),
    ).thenAnswer((_) async => stubConversation('c'));
    final m = InNoteMarker.forNote(
      index: 2,
      charStart: 0,
      charEnd: 5,
      conversationId: 'c',
      messageId: 'm',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InNoteMarkerPreview(marker: m)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Open image preview'), findsNothing);
    expect(find.byType(FullscreenImagePreview), findsNothing);
  });

  testWidgets('annotation marker image opens fullscreen preview', (
    tester,
  ) async {
    final imageFile = writeTempPng('annotation_marker');
    final annotation = NoteAnnotation(
      id: 'annotation-id',
      noteId: 'note-id',
      content: 'Remember this region',
      attachmentPaths: [imageFile.path],
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InNoteAnnotationPreview(
            annotation: annotation,
            isInScratchpad: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Annotation'), findsOneWidget);
    expect(find.byTooltip('Open image preview'), findsOneWidget);

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenImagePreview), findsOneWidget);
    expect(find.text('Annotation'), findsWidgets);
  });

  testWidgets(
    'AI marker delete affordance confirms and returns true without service delete',
    (tester) async {
      when(
        mockDb.getConversationMessage(any),
      ).thenAnswer((_) async => stubAnchorMessage());
      when(
        mockDb.getConversation('c'),
      ).thenAnswer((_) async => stubConversation('c'));
      final m = InNoteMarker.forNote(
        id: 'marker-id',
        index: 3,
        charStart: 0,
        charEnd: 5,
        conversationId: 'c',
        messageId: 'm',
      );
      bool? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showInNoteMarkerPreview(context, m);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Delete Marker'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete Marker'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Marker?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(fakeMarkerService.deletes, isEmpty);
    },
  );

  testWidgets(
    'orphan marker delete confirms and returns true without service delete',
    (tester) async {
      final m = InNoteMarker.forNote(
        id: 'orphan-marker',
        index: 0,
        charStart: 0,
        charEnd: 5,
        conversationId: 'c',
        messageId: 'm',
      );
      bool? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showInNoteMarkerPreview(context, m);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(MarkerOrphanState), findsOneWidget);

      await tester.tap(find.text('Delete marker'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Marker?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(fakeMarkerService.deletes, isEmpty);
    },
  );

  testWidgets(
    'stale lastViewedConversationId falls back to original and clears the pointer',
    (tester) async {
      when(
        mockDb.getConversationMessage(any),
      ).thenAnswer((_) async => stubAnchorMessage());
      when(mockDb.getConversation('stale')).thenAnswer((_) async => null);
      when(
        mockDb.getConversation('c'),
      ).thenAnswer((_) async => stubConversation('c'));
      final m = InNoteMarker.forNote(
        id: 'marker-id',
        index: 0,
        charStart: 0,
        charEnd: 5,
        conversationId: 'c',
        messageId: 'm',
        lastViewedConversationId: 'stale',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InNoteMarkerPreview(marker: m)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MarkerChatPanelHost), findsOneWidget);
      expect(fakeMarkerService.updates, isNotEmpty);
      expect(fakeMarkerService.updates.first.markerId, 'marker-id');
      expect(fakeMarkerService.updates.first.newConvId, isNull);
    },
  );
}
