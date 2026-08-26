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

      test('parses attachment URI', () {
        final link = SynapseResourceUri.parse(
          'synapseresource://attachment/abc-123',
        );
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.attachment);
        expect(link.id, 'abc-123');
        expect(link.queryParameters, isEmpty);
      });

      test('parses attachment URI with page query param', () {
        final link = SynapseResourceUri.parse(
          'synapseresource://attachment/abc-123?page=5',
        );
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.attachment);
        expect(link.id, 'abc-123');
        expect(link.queryParameters, {'page': '5'});
      });

      test('parses app URI with multiple query parameters', () {
        final link = SynapseResourceUri.parse(
          'synapseresource://app/my-app-uuid?note=current&zoom=12&style=dark',
        );
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.app);
        expect(link.id, 'my-app-uuid');
        expect(link.queryParameters, {
          'note': 'current',
          'zoom': '12',
          'style': 'dark',
        });
      });

      test('parses app URI without query parameters', () {
        final link = SynapseResourceUri.parse(
          'synapseresource://app/my-app-uuid',
        );
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.app);
        expect(link.id, 'my-app-uuid');
        expect(link.queryParameters, isEmpty);
      });

      test('parses URI with uppercase scheme', () {
        final link = SynapseResourceUri.parse('SYNAPSERESOURCE://note/abc');
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.note);
      });

      test('existing note/conversation URIs have empty queryParameters', () {
        final noteLink = SynapseResourceUri.parse('synapseresource://note/abc');
        expect(noteLink!.queryParameters, isEmpty);

        final convoLink = SynapseResourceUri.parse(
          'synapseresource://conversation/abc',
        );
        expect(convoLink!.queryParameters, isEmpty);
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

    group('attachmentUri', () {
      test('generates correct attachment URI without page', () {
        expect(
          SynapseResourceUri.attachmentUri('att-1'),
          'synapseresource://attachment/att-1',
        );
      });

      test('generates correct attachment URI with page', () {
        expect(
          SynapseResourceUri.attachmentUri('att-1', page: 5),
          'synapseresource://attachment/att-1?page=5',
        );
      });
    });

    group('figureUri', () {
      test('generates a figure URI with the chunkKey colons intact', () {
        expect(
          SynapseResourceUri.figureUri('n1:figure:att1:2000~abcdef012345'),
          'synapseresource://figure/n1:figure:att1:2000~abcdef012345',
        );
      });

      test('parses a figureId containing colons', () {
        final link = SynapseResourceUri.parse(
          'synapseresource://figure/note-1:figure:att-1:3000~aabbccddeeff',
        );
        expect(link, isNotNull);
        expect(link!.type, SynapseResourceType.figure);
        expect(link.id, 'note-1:figure:att-1:3000~aabbccddeeff');
        expect(link.queryParameters, isEmpty);
      });

      test('round-trips a figureId whose chunkKey contains a tilde', () {
        // chunkKeys are not expected to contain `~`, but the split-on-LAST-`~`
        // contract must survive one if a note id ever does.
        const figureId = 'no~te:figure:att-1:0~aabbccddeeff';
        final parsed = SynapseResourceUri.parse(
          SynapseResourceUri.figureUri(figureId),
        );
        expect(parsed!.type, SynapseResourceType.figure);
        expect(parsed.id, figureId);
        expect(
          parsed.id.substring(parsed.id.lastIndexOf('~') + 1),
          'aabbccddeeff',
        );
      });

      test('round-trips ids with characters that need encoding', () {
        const figureId = 'note a/b:figure:att 1:0~aabbccddeeff';
        final uri = SynapseResourceUri.figureUri(figureId);
        expect(uri.contains(' '), isFalse);
        final parsed = SynapseResourceUri.parse(uri);
        expect(parsed!.type, SynapseResourceType.figure);
        expect(parsed.id, figureId);
      });
    });

    group('appUri', () {
      test('generates correct app URI without params', () {
        expect(
          SynapseResourceUri.appUri('app-uuid-1'),
          'synapseresource://app/app-uuid-1',
        );
      });

      test('generates correct app URI with params', () {
        final uri = SynapseResourceUri.appUri(
          'app-uuid-1',
          params: {'note': 'current', 'zoom': '12'},
        );
        final parsed = SynapseResourceUri.parse(uri);
        expect(parsed, isNotNull);
        expect(parsed!.type, SynapseResourceType.app);
        expect(parsed.id, 'app-uuid-1');
        expect(parsed.queryParameters['note'], 'current');
        expect(parsed.queryParameters['zoom'], '12');
      });

      test('encodes values with special characters', () {
        final uri = SynapseResourceUri.appUri(
          'app-uuid-1',
          params: {'q': 'hello world & stuff'},
        );
        final parsed = SynapseResourceUri.parse(uri);
        expect(parsed!.queryParameters['q'], 'hello world & stuff');
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

      test('attachmentUri can be parsed back', () {
        const attachmentId = 'test-att-789';
        final uri = SynapseResourceUri.attachmentUri(attachmentId);
        final parsed = SynapseResourceUri.parse(uri);
        expect(parsed, isNotNull);
        expect(parsed!.type, SynapseResourceType.attachment);
        expect(parsed.id, attachmentId);
        expect(parsed.queryParameters, isEmpty);
      });

      test('attachmentUri with page can be parsed back', () {
        const attachmentId = 'test-att-789';
        final uri = SynapseResourceUri.attachmentUri(attachmentId, page: 42);
        final parsed = SynapseResourceUri.parse(uri);
        expect(parsed, isNotNull);
        expect(parsed!.type, SynapseResourceType.attachment);
        expect(parsed.id, attachmentId);
        expect(parsed.queryParameters['page'], '42');
      });

      test('appUri with params can be parsed back', () {
        const appUuid = 'test-app-uuid';
        final uri = SynapseResourceUri.appUri(
          appUuid,
          params: {'note': 'current', 'style': 'dark'},
        );
        final parsed = SynapseResourceUri.parse(uri);
        expect(parsed, isNotNull);
        expect(parsed!.type, SynapseResourceType.app);
        expect(parsed.id, appUuid);
        expect(parsed.queryParameters['note'], 'current');
        expect(parsed.queryParameters['style'], 'dark');
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

      test('different queryParameters are not equal', () {
        final link1 = SynapseResourceLink(
          type: SynapseResourceType.attachment,
          id: 'abc',
          queryParameters: {'page': '1'},
        );
        final link2 = SynapseResourceLink(
          type: SynapseResourceType.attachment,
          id: 'abc',
          queryParameters: {'page': '2'},
        );
        expect(link1, isNot(link2));
      });

      test('same queryParameters are equal', () {
        final link1 = SynapseResourceLink(
          type: SynapseResourceType.attachment,
          id: 'abc',
          queryParameters: {'page': '5'},
        );
        final link2 = SynapseResourceLink(
          type: SynapseResourceType.attachment,
          id: 'abc',
          queryParameters: {'page': '5'},
        );
        expect(link1, link2);
        expect(link1.hashCode, link2.hashCode);
      });
    });
  });
}
