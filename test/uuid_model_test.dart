import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/attachment.dart';

void main() {
  group('UUID Model Generation', () {
    test('Filter should generate UUID when id is null', () {
      final filter1 = Filter(
        name: 'Test Filter 1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final filter2 = Filter(
        name: 'Test Filter 2',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(filter1.id, isNotEmpty);
      expect(filter2.id, isNotEmpty);
      expect(filter1.id, isNot(filter2.id));
      // UUID v4 format check (simple regex)
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      );
      expect(uuidRegex.hasMatch(filter1.id), isTrue);
    });

    test('Attachment should generate UUID when id is null', () {
      final attachment1 = Attachment(
        noteId: 'note-1',
        filePath: 'path/to/file1',
        fileName: 'file1.txt',
        fileType: 'text/plain',
        createdAt: DateTime.now(),
      );
      final attachment2 = Attachment(
        noteId: 'note-2',
        filePath: 'path/to/file2',
        fileName: 'file2.txt',
        fileType: 'text/plain',
        createdAt: DateTime.now(),
      );

      expect(attachment1.id, isNotEmpty);
      expect(attachment2.id, isNotEmpty);
      expect(attachment1.id, isNot(attachment2.id));
      // UUID v4 format check
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      );
      expect(uuidRegex.hasMatch(attachment1.id), isTrue);
    });

    test('Filter should preserve provided id', () {
      const explicitId = 'explicit-id-123';
      final filter = Filter(
        id: explicitId,
        name: 'Test Filter',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(filter.id, explicitId);
    });

    test('Attachment should preserve provided id', () {
      const explicitId = 'explicit-id-456';
      final attachment = Attachment(
        id: explicitId,
        noteId: 'note-1',
        filePath: 'path/to/file',
        fileName: 'file.txt',
        fileType: 'text/plain',
        createdAt: DateTime.now(),
      );
      expect(attachment.id, explicitId);
    });
  });
}
