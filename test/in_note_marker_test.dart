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

    test('forNote preserves normalizedRect when provided', () {
      final rect = NormalizedRect(x: 0.1, y: 0.2, w: 0.5, h: 0.3);
      final marker = InNoteMarker.forNote(
        index: 1,
        charStart: 0,
        charEnd: 0,
        normalizedRect: rect,
        conversationId: 'c',
        messageId: 'm',
      );
      expect(marker.normalizedRect, isNotNull);
      expect(marker.normalizedRect!.x, closeTo(0.1, 0.001));

      // Round-trip
      final restored = InNoteMarker.fromJson(marker.toJson());
      expect(restored.normalizedRect, isNotNull);
      expect(restored.normalizedRect!.y, closeTo(0.2, 0.001));
    });
  });

  group('MarkerType', () {
    test('attachment marker defaults to ai type', () {
      final m = InNoteMarker.forAttachment(
        index: 1, page: 0,
        normalizedRect: NormalizedRect(x: 0, y: 0, w: 1, h: 1),
        conversationId: 'c', messageId: 'm',
      );
      expect(m.type, MarkerType.ai);
    });

    test('note marker defaults to ai type', () {
      final m = InNoteMarker.forNote(
        index: 1, charStart: 0, charEnd: 0,
        conversationId: 'c', messageId: 'm',
      );
      expect(m.type, MarkerType.ai);
    });

    test('annotation type round-trips through JSON', () {
      final m = InNoteMarker.forAttachment(
        index: 1, page: 0,
        normalizedRect: NormalizedRect(x: 0, y: 0, w: 1, h: 1),
        conversationId: 'c', messageId: 'm',
        type: MarkerType.annotation,
      );
      final restored = InNoteMarker.fromJson(m.toJson());
      expect(restored.type, MarkerType.annotation);
    });

    test('JSON without type field defaults to ai (backward compat)', () {
      final json = {
        'id': 'x', 'index': 1, 'conversationId': 'c',
        'messageId': 'm', 'createdAt': '2026-01-01T00:00:00.000Z',
      };
      final m = InNoteMarker.fromJson(json);
      expect(m.type, MarkerType.ai);
    });
  });
}
