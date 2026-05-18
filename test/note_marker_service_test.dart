import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_marker_service.dart';
import 'package:note_synapse/services/service_locator.dart';

@GenerateMocks([DatabaseService])
import 'note_marker_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late NoteMarkerService service;

  final testMarker = InNoteMarker.forAttachment(
    id: 'marker-1',
    index: 0,
    page: 2,
    normalizedRect: const NormalizedRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4),
    conversationId: 'conv-1',
    messageId: 'msg-1',
    createdAt: DateTime(2026, 3, 1),
  );

  Attachment makeAttachment({Map<String, dynamic>? metadata}) => Attachment(
    id: 'attach-1',
    noteId: 'note-1',
    filePath: 'test.pdf',
    fileName: 'test.pdf',
    fileType: 'pdf',
    createdAt: DateTime(2026, 1, 1),
    metadata: metadata,
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteMarkerService(mockDb);
  });

  // ── Attachment markers ──────────────────────────────────────────────────

  group('saveMarkerForAttachment', () {
    test('saves marker when attachment has no prior metadata', () async {
      when(
        mockDb.getAttachmentById('attach-1'),
      ).thenAnswer((_) async => makeAttachment());
      when(
        mockDb.updateAttachmentMetadata('attach-1', any),
      ).thenAnswer((_) async {});

      await service.saveMarkerForAttachment('attach-1', testMarker);

      final captured = verify(
        mockDb.updateAttachmentMetadata('attach-1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(markers.length, 1);
      expect(markers.first['id'], 'marker-1');
    });

    test('appends marker to existing markers', () async {
      final existing = testMarker.toJson();
      existing['id'] = 'marker-0';
      when(
        mockDb.getAttachmentById('attach-1'),
      ).thenAnswer(
        (_) async => makeAttachment(
          metadata: {'markers': [existing]},
        ),
      );
      when(
        mockDb.updateAttachmentMetadata('attach-1', any),
      ).thenAnswer((_) async {});

      await service.saveMarkerForAttachment('attach-1', testMarker);

      final captured = verify(
        mockDb.updateAttachmentMetadata('attach-1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(markers.length, 2);
      expect(markers[0]['id'], 'marker-0');
      expect(markers[1]['id'], 'marker-1');
    });
  });

  group('getMarkersForAttachment', () {
    test('returns empty list when attachment has no metadata', () async {
      when(
        mockDb.getAttachmentById('attach-1'),
      ).thenAnswer((_) async => makeAttachment());

      final result = await service.getMarkersForAttachment('attach-1');
      expect(result, isEmpty);
    });

    test('returns deserialized markers', () async {
      when(
        mockDb.getAttachmentById('attach-1'),
      ).thenAnswer(
        (_) async => makeAttachment(
          metadata: {'markers': [testMarker.toJson()]},
        ),
      );

      final result = await service.getMarkersForAttachment('attach-1');
      expect(result.length, 1);
      expect(result.first.id, 'marker-1');
      expect(result.first.page, 2);
    });
  });

  group('deleteMarkerForAttachment', () {
    test('removes marker by id', () async {
      final m1 = InNoteMarker.forAttachment(
        id: 'marker-a',
        index: 0,
        page: 1,
        normalizedRect: const NormalizedRect(x: 0, y: 0, w: 1, h: 1),
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );
      final m2 = InNoteMarker.forAttachment(
        id: 'marker-b',
        index: 1,
        page: 1,
        normalizedRect: const NormalizedRect(x: 0, y: 0, w: 1, h: 1),
        conversationId: 'conv-1',
        messageId: 'msg-2',
      );

      when(
        mockDb.getAttachmentById('attach-1'),
      ).thenAnswer(
        (_) async => makeAttachment(
          metadata: {'markers': [m1.toJson(), m2.toJson()]},
        ),
      );
      when(
        mockDb.updateAttachmentMetadata('attach-1', any),
      ).thenAnswer((_) async {});

      await service.deleteMarkerForAttachment('attach-1', 'marker-a');

      final captured = verify(
        mockDb.updateAttachmentMetadata('attach-1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(markers.length, 1);
      expect((markers.first as Map<String, dynamic>)['id'], 'marker-b');
    });
  });

  // ── Note markers ────────────────────────────────────────────────────────

  group('saveMarkerForNote', () {
    test('saves marker when note has no prior metadata', () async {
      when(
        mockDb.getNoteMetadata('note-1'),
      ).thenAnswer((_) async => null);
      when(
        mockDb.updateNoteMetadata('note-1', any),
      ).thenAnswer((_) async {});

      final noteMarker = InNoteMarker.forNote(
        id: 'note-marker-1',
        index: 0,
        charStart: 10,
        charEnd: 20,
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );
      await service.saveMarkerForNote('note-1', noteMarker);

      final captured = verify(
        mockDb.updateNoteMetadata('note-1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(markers.length, 1);
      expect(markers.first['id'], 'note-marker-1');
    });
  });

  group('getMarkersForNote', () {
    test('returns empty list when note has no metadata', () async {
      when(
        mockDb.getNoteMetadata('note-1'),
      ).thenAnswer((_) async => null);

      final result = await service.getMarkersForNote('note-1');
      expect(result, isEmpty);
    });
  });

  group('deleteMarkerForNote', () {
    test('removes note marker by id', () async {
      final nm1 = InNoteMarker.forNote(
        id: 'nm-a',
        index: 0,
        charStart: 0,
        charEnd: 5,
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );
      final nm2 = InNoteMarker.forNote(
        id: 'nm-b',
        index: 1,
        charStart: 10,
        charEnd: 15,
        conversationId: 'conv-1',
        messageId: 'msg-2',
      );

      when(
        mockDb.getNoteMetadata('note-1'),
      ).thenAnswer(
        (_) async => {'markers': [nm1.toJson(), nm2.toJson()]},
      );
      when(
        mockDb.updateNoteMetadata('note-1', any),
      ).thenAnswer((_) async {});

      await service.deleteMarkerForNote('note-1', 'nm-a');

      final captured = verify(
        mockDb.updateNoteMetadata('note-1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(markers.length, 1);
      expect((markers.first as Map<String, dynamic>)['id'], 'nm-b');
    });
  });

  // ── Marker-by-id (parent-agnostic) operations (Task 24) ─────────────────

  Note makeNote(String id) => Note(
        id: id,
        title: 'note $id',
        content: '',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  InNoteMarker makeNoteMarker({String id = 'mk1', String? lastViewed}) =>
      InNoteMarker.forNote(
        id: id,
        index: 0,
        charStart: 0,
        charEnd: 5,
        conversationId: 'c-original',
        messageId: 'm',
        lastViewedConversationId: lastViewed,
      );

  Map<String, dynamic> makeAttachmentRow({
    required String id,
    required InNoteMarker marker,
  }) => {
        'id': id,
        'noteId': 'n1',
        'fileName': 'pdf.pdf',
        'fileType': 'pdf',
        'filePath': 'attachments/pdf.pdf',
        'isRelativePath': 1,
        'includeInAIContext': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'metadata': jsonEncode({'markers': [marker.toJson()]}),
      };

  group('updateMarkerLastViewed', () {
    test('sets lastViewedConversationId on a note marker', () async {
      final marker = makeNoteMarker();
      when(mockDb.getAllNotes()).thenAnswer((_) async => [makeNote('n1')]);
      when(mockDb.getNoteMetadata('n1')).thenAnswer((_) async => {
            'markers': [marker.toJson()],
          });
      when(mockDb.updateNoteMetadata(any, any)).thenAnswer((_) async {});
      when(mockDb.getAllAttachments()).thenAnswer((_) async => const []);

      await service.updateMarkerLastViewed('mk1', 'c-new');

      final captured = verify(
        mockDb.updateNoteMetadata('n1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(markers, hasLength(1));
      expect(
        (markers.first as Map<String, dynamic>)['lastViewedConversationId'],
        'c-new',
      );
    });

    test('clears lastViewedConversationId when newConvId is null', () async {
      final marker = makeNoteMarker(lastViewed: 'stale');
      when(mockDb.getAllNotes()).thenAnswer((_) async => [makeNote('n1')]);
      when(mockDb.getNoteMetadata('n1')).thenAnswer((_) async => {
            'markers': [marker.toJson()],
          });
      when(mockDb.updateNoteMetadata(any, any)).thenAnswer((_) async {});
      when(mockDb.getAllAttachments()).thenAnswer((_) async => const []);

      await service.updateMarkerLastViewed('mk1', null);

      final captured = verify(
        mockDb.updateNoteMetadata('n1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(
        (markers.first as Map<String, dynamic>)
            .containsKey('lastViewedConversationId'),
        isFalse,
      );
    });

    test('falls through to attachments when not found in any note', () async {
      final marker = makeNoteMarker(id: 'attMk');
      when(mockDb.getAllNotes()).thenAnswer((_) async => const []);
      when(mockDb.getAllAttachments()).thenAnswer(
        (_) async => [makeAttachmentRow(id: 'a1', marker: marker)],
      );
      when(mockDb.updateAttachmentMetadata(any, any))
          .thenAnswer((_) async {});

      await service.updateMarkerLastViewed('attMk', 'c-new');

      final captured = verify(
        mockDb.updateAttachmentMetadata('a1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(
        (markers.first as Map<String, dynamic>)['lastViewedConversationId'],
        'c-new',
      );
    });

    test('no-ops when marker is not found anywhere', () async {
      when(mockDb.getAllNotes()).thenAnswer((_) async => const []);
      when(mockDb.getAllAttachments()).thenAnswer((_) async => const []);

      await service.updateMarkerLastViewed('missing', 'c-new');

      verifyNever(mockDb.updateNoteMetadata(any, any));
      verifyNever(mockDb.updateAttachmentMetadata(any, any));
    });
  });

  group('deleteMarker (by id)', () {
    test('removes marker from a note when found there', () async {
      final marker = makeNoteMarker(id: 'mk1');
      when(mockDb.getAllNotes()).thenAnswer((_) async => [makeNote('n1')]);
      when(mockDb.getNoteMetadata('n1')).thenAnswer((_) async => {
            'markers': [marker.toJson()],
          });
      when(mockDb.updateNoteMetadata(any, any)).thenAnswer((_) async {});
      when(mockDb.getAllAttachments()).thenAnswer((_) async => const []);

      await service.deleteMarker('mk1');

      // deleteMarkerForNote re-fetches metadata then writes back without
      // the marker. Capture the *last* write so we get the final state.
      final captures = verify(
        mockDb.updateNoteMetadata('n1', captureAny),
      ).captured;
      final last = captures.last as Map<String, dynamic>;
      expect(last['markers'] as List, isEmpty);
    });

    test('dispatches to the attachment helper when found there', () async {
      final marker = makeNoteMarker(id: 'attMk');
      when(mockDb.getAllNotes()).thenAnswer((_) async => const []);
      when(mockDb.getAllAttachments()).thenAnswer(
        (_) async => [makeAttachmentRow(id: 'a1', marker: marker)],
      );
      // deleteMarkerForAttachment re-fetches via getAttachmentById; null is
      // tolerated (the inner method just early-returns), letting us assert
      // dispatch without re-stubbing the full attachment fetch path.
      when(mockDb.getAttachmentById('a1')).thenAnswer((_) async => null);

      await service.deleteMarker('attMk');

      verify(mockDb.getAttachmentById('a1')).called(1);
    });

    test('no-ops when marker is not found anywhere', () async {
      when(mockDb.getAllNotes()).thenAnswer((_) async => const []);
      when(mockDb.getAllAttachments()).thenAnswer((_) async => const []);

      await service.deleteMarker('missing');

      verifyNever(mockDb.updateNoteMetadata(any, any));
      verifyNever(mockDb.updateAttachmentMetadata(any, any));
    });
  });
}
