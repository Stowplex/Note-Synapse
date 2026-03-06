import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note_annotation.dart';

void main() {
  group('NoteAnnotation', () {
    test('round-trips for note-based annotation', () {
      final a = NoteAnnotation(
        id: 'ann-1',
        noteId: 'note-a',
        content: 'hello world',
        attachmentPaths: ['path/a.png'],
        createdAt: DateTime.utc(2026, 3, 6),
      );
      final map = a.toMap();
      final restored = NoteAnnotation.fromMap(map);
      expect(restored.id, 'ann-1');
      expect(restored.noteId, 'note-a');
      expect(restored.attachmentId, isNull);
      expect(restored.content, 'hello world');
      expect(restored.attachmentPaths, ['path/a.png']);
      expect(restored.createdAt, DateTime.utc(2026, 3, 6));
    });

    test('round-trips for attachment-based annotation', () {
      final a = NoteAnnotation(
        id: 'ann-2',
        attachmentId: 'att-b',
        content: 'circle this',
        attachmentPaths: [],
        createdAt: DateTime.utc(2026, 3, 6),
      );
      final map = a.toMap();
      final restored = NoteAnnotation.fromMap(map);
      expect(restored.attachmentId, 'att-b');
      expect(restored.noteId, isNull);
      expect(restored.attachmentPaths, isEmpty);
    });

    test('toMap stores attachmentPaths as JSON string', () {
      final a = NoteAnnotation(
        id: 'x',
        content: 'y',
        attachmentPaths: ['a', 'b'],
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final map = a.toMap();
      expect(map['attachment_paths'], isA<String>());
      expect(map['attachment_paths'] as String, contains('"a"'));
    });
  });
}
