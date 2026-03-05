import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/in_note_marker.dart';

void main() {
  group('NormalizedRect', () {
    test('roundtrips through JSON', () {
      final rect = NormalizedRect(x: 0.1, y: 0.2, w: 0.3, h: 0.15);
      final json = rect.toJson();
      final restored = NormalizedRect.fromJson(json);
      expect(restored.x, closeTo(0.1, 0.001));
      expect(restored.y, closeTo(0.2, 0.001));
      expect(restored.w, closeTo(0.3, 0.001));
      expect(restored.h, closeTo(0.15, 0.001));
    });
  });

  group('InNoteMarker', () {
    test('roundtrips attachment marker through JSON', () {
      final marker = InNoteMarker.forAttachment(
        id: 'test-id',
        index: 1,
        page: 3,
        normalizedRect: NormalizedRect(x: 0.1, y: 0.2, w: 0.3, h: 0.15),
        conversationId: 'conv-1',
        messageId: 'msg-1',
        createdAt: DateTime.utc(2026, 3, 4),
      );
      final json = marker.toJson();
      final restored = InNoteMarker.fromJson(json);
      expect(restored.id, 'test-id');
      expect(restored.index, 1);
      expect(restored.page, 3);
      expect(restored.normalizedRect, isNotNull);
      expect(restored.normalizedRect!.x, closeTo(0.1, 0.001));
      expect(restored.conversationId, 'conv-1');
      expect(restored.messageId, 'msg-1');
      expect(restored.charStart, isNull);
    });

    test('roundtrips text note marker through JSON', () {
      final marker = InNoteMarker.forNote(
        id: 'note-marker-id',
        index: 2,
        charStart: 120,
        charEnd: 250,
        conversationId: 'conv-2',
        messageId: 'msg-2',
        createdAt: DateTime.utc(2026, 3, 4),
      );
      final json = marker.toJson();
      final restored = InNoteMarker.fromJson(json);
      expect(restored.charStart, 120);
      expect(restored.charEnd, 250);
      expect(restored.normalizedRect, isNull);
      expect(restored.page, isNull);
    });
  });
}
