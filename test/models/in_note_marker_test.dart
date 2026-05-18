import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/in_note_marker.dart';

void main() {
  group('InNoteMarker JSON with lastViewedConversationId', () {
    test('toJson includes lastViewedConversationId when set', () {
      final m = InNoteMarker.forNote(
        index: 0,
        charStart: 10,
        charEnd: 20,
        conversationId: 'conv-orig',
        messageId: 'msg-1',
        lastViewedConversationId: 'conv-branch-A',
      );
      final json = m.toJson();
      expect(json['lastViewedConversationId'], 'conv-branch-A');
    });

    test('toJson omits lastViewedConversationId when null', () {
      final m = InNoteMarker.forNote(
        index: 0,
        charStart: 0,
        charEnd: 5,
        conversationId: 'conv',
        messageId: 'msg',
      );
      final json = m.toJson();
      expect(json.containsKey('lastViewedConversationId'), isFalse);
    });

    test('fromJson defaults lastViewedConversationId to null when absent (pre-v1 markers)', () {
      final preV1Json = {
        'id': 'marker-1',
        'index': 0,
        'conversationId': 'conv',
        'messageId': 'msg',
        'createdAt': DateTime.now().toIso8601String(),
      };
      final m = InNoteMarker.fromJson(preV1Json);
      expect(m.lastViewedConversationId, isNull);
    });

    test('fromJson reads lastViewedConversationId when present', () {
      final json = {
        'id': 'marker-1',
        'index': 0,
        'conversationId': 'conv',
        'messageId': 'msg',
        'createdAt': DateTime.now().toIso8601String(),
        'lastViewedConversationId': 'conv-branch-X',
      };
      final m = InNoteMarker.fromJson(json);
      expect(m.lastViewedConversationId, 'conv-branch-X');
    });

    test('forAttachment factory accepts lastViewedConversationId', () {
      final m = InNoteMarker.forAttachment(
        index: 0,
        page: 1,
        conversationId: 'c',
        messageId: 'm',
        lastViewedConversationId: 'lv',
      );
      expect(m.lastViewedConversationId, 'lv');
    });

    test('round-trip via toJson/fromJson preserves lastViewedConversationId', () {
      final original = InNoteMarker.forNote(
        index: 2,
        charStart: 0,
        charEnd: 10,
        conversationId: 'c',
        messageId: 'm',
        lastViewedConversationId: 'branch-Z',
      );
      final restored = InNoteMarker.fromJson(original.toJson());
      expect(restored.lastViewedConversationId, 'branch-Z');
    });

    test('forAttachment round-trip preserves lastViewedConversationId', () {
      final original = InNoteMarker.forAttachment(
        index: 1,
        page: 3,
        conversationId: 'c',
        messageId: 'm',
        lastViewedConversationId: 'attachment-branch',
      );
      final restored = InNoteMarker.fromJson(original.toJson());
      expect(restored.lastViewedConversationId, 'attachment-branch');
    });

    test('toJson serializes empty string as-is (does not omit) — caller must validate', () {
      // Documents the boundary: toJson omits ONLY when null. An empty
      // string is preserved through serialization. Task 24's writers
      // must not store '' as a sentinel for "no last view" — use null.
      final m = InNoteMarker.forNote(
        index: 0,
        charStart: 0,
        charEnd: 1,
        conversationId: 'c',
        messageId: 'm',
        lastViewedConversationId: '',
      );
      final json = m.toJson();
      expect(json['lastViewedConversationId'], '');
      final restored = InNoteMarker.fromJson(json);
      expect(restored.lastViewedConversationId, '');
    });
  });
}
