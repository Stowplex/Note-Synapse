import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/synapse_resource_uri.dart';

void main() {
  group('SynapseResourceUri', () {
    group('isSynapseResourceUri', () {
      test('returns true for valid note URI', () {
        expect(
          SynapseResourceUri.isSynapseResourceUri('synapseresource://note/abc'),
          isTrue,
        );
      });

      test('returns true for valid conversation URI', () {
        expect(
          SynapseResourceUri.isSynapseResourceUri(
            'synapseresource://conversation/xyz',
          ),
          isTrue,
        );
      });

      test('returns true regardless of case', () {
        expect(
          SynapseResourceUri.isSynapseResourceUri('SYNAPSERESOURCE://note/abc'),
          isTrue,
        );
      });

      test('returns false for http URLs', () {
        expect(
          SynapseResourceUri.isSynapseResourceUri('https://example.com'),
          isFalse,
        );
      });

      test('returns false for empty string', () {
        expect(SynapseResourceUri.isSynapseResourceUri(''), isFalse);
      });

      test('returns false for random text', () {
        expect(
          SynapseResourceUri.isSynapseResourceUri('some random text'),
          isFalse,
        );
      });
    });

    group('parse', () {
      test('parses valid note URI', () {
        final link = SynapseResourceUri.parse('synapseresource://note/abc-123');
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.note);
        expect(link.id, 'abc-123');
      });

      test('parses valid conversation URI', () {
        final link = SynapseResourceUri.parse(
          'synapseresource://conversation/xyz-456',
        );
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.conversation);
        expect(link.id, 'xyz-456');
      });

      test('parses URI with uppercase scheme', () {
        final link = SynapseResourceUri.parse('SYNAPSERESOURCE://note/abc');
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.note);
      });

      test('returns null for unknown resource type', () {
        final link = SynapseResourceUri.parse('synapseresource://unknown/abc');
        expect(link, isNull);
      });

      test('returns null for missing ID', () {
        final link = SynapseResourceUri.parse('synapseresource://note/');
        expect(link, isNull);
      });

      test('returns null for non-synapseresource URI', () {
        final link = SynapseResourceUri.parse('https://example.com');
        expect(link, isNull);
      });

      test('returns null for malformed URI', () {
        final link = SynapseResourceUri.parse('synapseresource://');
        expect(link, isNull);
      });
    });

    group('noteUri', () {
      test('generates correct note URI', () {
        expect(
          SynapseResourceUri.noteUri('my-note-id'),
          'synapseresource://note/my-note-id',
        );
      });

      test('handles UUID-style IDs', () {
        expect(
          SynapseResourceUri.noteUri('550e8400-e29b-41d4-a716-446655440000'),
          'synapseresource://note/550e8400-e29b-41d4-a716-446655440000',
        );
      });
    });

    group('conversationUri', () {
      test('generates correct conversation URI', () {
        expect(
          SynapseResourceUri.conversationUri('my-convo-id'),
          'synapseresource://conversation/my-convo-id',
        );
      });
    });

    group('roundtrip', () {
      test('noteUri can be parsed back', () {
        const noteId = 'test-note-123';
        final uri = SynapseResourceUri.noteUri(noteId);
        final parsed = SynapseResourceUri.parse(uri);
        expect(parsed, isNotNull);
        expect(parsed!.type, SynapseResourceType.note);
        expect(parsed.id, noteId);
      });

      test('conversationUri can be parsed back', () {
        const conversationId = 'test-convo-456';
        final uri = SynapseResourceUri.conversationUri(conversationId);
        final parsed = SynapseResourceUri.parse(uri);
        expect(parsed, isNotNull);
        expect(parsed!.type, SynapseResourceType.conversation);
        expect(parsed.id, conversationId);
      });
    });

    group('SynapseResourceLink equality', () {
      test('equal links are equal', () {
        final link1 = SynapseResourceLink(
          type: SynapseResourceType.note,
          id: 'abc',
        );
        final link2 = SynapseResourceLink(
          type: SynapseResourceType.note,
          id: 'abc',
        );
        expect(link1, link2);
        expect(link1.hashCode, link2.hashCode);
      });

      test('different types are not equal', () {
        final link1 = SynapseResourceLink(
          type: SynapseResourceType.note,
          id: 'abc',
        );
        final link2 = SynapseResourceLink(
          type: SynapseResourceType.conversation,
          id: 'abc',
        );
        expect(link1, isNot(link2));
      });

      test('different ids are not equal', () {
        final link1 = SynapseResourceLink(
          type: SynapseResourceType.note,
          id: 'abc',
        );
        final link2 = SynapseResourceLink(
          type: SynapseResourceType.note,
          id: 'xyz',
        );
        expect(link1, isNot(link2));
      });
    });
  });
}
