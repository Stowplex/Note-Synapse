import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/attachment_link_service.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/service_locator.dart';

@GenerateMocks([DatabaseService])
import 'attachment_link_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late AttachmentLinkService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = AttachmentLinkService(mockDb);
  });

  group('resolveAttachmentLink', () {
    test('returns AttachmentLinkResult with attachment and parent note', () async {
      final attachment = Attachment(
        id: 'att-1',
        noteId: 'note-1',
        filePath: 'path/to/file.pdf',
        fileName: 'file.pdf',
        fileType: 'application/pdf',
        createdAt: DateTime.now(),
      );
      final note = Note(
        id: 'note-1',
        title: 'Test Note',
        content: 'content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(mockDb.getAttachmentById('att-1')).thenAnswer((_) async => attachment);
      when(mockDb.getNote('note-1')).thenAnswer((_) async => note);

      final result = await service.resolveAttachmentLink('att-1');

      expect(result, isNotNull);
      expect(result!.attachment, equals(attachment));
      expect(result.note, equals(note));
      verify(mockDb.getAttachmentById('att-1')).called(1);
      verify(mockDb.getNote('note-1')).called(1);
    });

    test('returns null when attachment is not found', () async {
      when(mockDb.getAttachmentById('missing')).thenAnswer((_) async => null);

      final result = await service.resolveAttachmentLink('missing');

      expect(result, isNull);
      verify(mockDb.getAttachmentById('missing')).called(1);
      verifyNever(mockDb.getNote(any));
    });

    test('returns null when parent note is not found', () async {
      final attachment = Attachment(
        id: 'att-1',
        noteId: 'note-missing',
        filePath: 'path/to/file.pdf',
        fileName: 'file.pdf',
        fileType: 'application/pdf',
        createdAt: DateTime.now(),
      );

      when(mockDb.getAttachmentById('att-1')).thenAnswer((_) async => attachment);
      when(mockDb.getNote('note-missing')).thenAnswer((_) async => null);

      final result = await service.resolveAttachmentLink('att-1');

      expect(result, isNull);
    });
  });

  group('generateMarkdownLink', () {
    test('generates link with page parameter', () {
      final result = service.generateMarkdownLink(
        attachmentId: 'att-1',
        linkText: 'text',
        page: 5,
      );
      expect(result, '[text](synapseresource://attachment/att-1?page=5)');
    });

    test('generates link without page parameter', () {
      final result = service.generateMarkdownLink(
        attachmentId: 'att-1',
        linkText: 'text',
      );
      expect(result, '[text](synapseresource://attachment/att-1)');
    });
  });

  group('defaultLinkText', () {
    test('returns fileName when no optional params', () {
      expect(
        service.defaultLinkText(fileName: 'report.pdf'),
        'report.pdf',
      );
    });

    test('returns fileName with page suffix', () {
      expect(
        service.defaultLinkText(fileName: 'report.pdf', page: 5),
        'report.pdf - Page 5',
      );
    });

    test('returns bookmarkTitle when provided', () {
      expect(
        service.defaultLinkText(fileName: 'report.pdf', bookmarkTitle: 'Ch 3'),
        'Ch 3',
      );
    });

    test('returns chapterTitle when provided', () {
      expect(
        service.defaultLinkText(
          fileName: 'report.pdf',
          chapterTitle: 'Introduction',
        ),
        'Introduction',
      );
    });

    test('bookmarkTitle takes priority over chapterTitle', () {
      expect(
        service.defaultLinkText(
          fileName: 'report.pdf',
          bookmarkTitle: 'Ch 3',
          chapterTitle: 'Introduction',
        ),
        'Ch 3',
      );
    });

    test('bookmarkTitle takes priority over page', () {
      expect(
        service.defaultLinkText(
          fileName: 'report.pdf',
          bookmarkTitle: 'Ch 3',
          page: 5,
        ),
        'Ch 3',
      );
    });

    test('chapterTitle takes priority over page', () {
      expect(
        service.defaultLinkText(
          fileName: 'report.pdf',
          chapterTitle: 'Introduction',
          page: 5,
        ),
        'Introduction',
      );
    });
  });
}
