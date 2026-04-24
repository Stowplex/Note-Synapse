import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/synapse_app_block_syntax.dart';

void main() {
  group('SynapseAppBlockBody.parse', () {
    test('parses minimal YAML body', () {
      final body = SynapseAppBlockBody.parse('app: my-uuid');
      expect(body.isValid, isTrue);
      expect(body.appUuid, 'my-uuid');
      expect(body.revisionNumber, isNull);
      expect(body.width, isNull);
      expect(body.height, isNull);
      expect(body.noteSelectors, isEmpty);
      expect(body.params, isEmpty);
    });

    test('parses full YAML body', () {
      const raw = '''
app: my-app-uuid
revision: 3
width: 600
height: 400
notes:
  - current
  - some-note-id
params:
  zoom: 12
  style: dark
  pins:
    - lat: 37.77
      lng: -122.41
      label: SF
''';
      final body = SynapseAppBlockBody.parse(raw);
      expect(body.isValid, isTrue);
      expect(body.appUuid, 'my-app-uuid');
      expect(body.revisionNumber, 3);
      expect(body.width, 600.0);
      expect(body.height, 400.0);
      expect(body.noteSelectors, ['current', 'some-note-id']);
      expect(body.params['zoom'], 12);
      expect(body.params['style'], 'dark');
      final pins = body.params['pins'] as List;
      expect(pins, hasLength(1));
      expect((pins[0] as Map)['label'], 'SF');
    });

    test('parses JSON body (YAML superset)', () {
      const raw = '{"app": "json-uuid", "params": {"k": 42}}';
      final body = SynapseAppBlockBody.parse(raw);
      expect(body.isValid, isTrue);
      expect(body.appUuid, 'json-uuid');
      expect(body.params['k'], 42);
    });

    test('accepts notes as comma-separated string', () {
      const raw = 'app: x\nnotes: current,abc,def';
      final body = SynapseAppBlockBody.parse(raw);
      expect(body.noteSelectors, ['current', 'abc', 'def']);
    });

    test('produces an error for empty body', () {
      final body = SynapseAppBlockBody.parse('');
      expect(body.isValid, isFalse);
      expect(body.error, isNotNull);
    });

    test('produces an error when app key is missing', () {
      final body = SynapseAppBlockBody.parse('revision: 1\nwidth: 100');
      expect(body.isValid, isFalse);
      expect(body.error, contains('app'));
    });

    test('produces an error for non-object body', () {
      final body = SynapseAppBlockBody.parse('just some text');
      expect(body.isValid, isFalse);
      expect(body.error, isNotNull);
    });
  });

  group('findSynapseAppBlocks', () {
    test('finds a single block inside markdown', () {
      const source =
          'Some intro text\n\n'
          '```synapse-app\n'
          'app: my-uuid\n'
          'params:\n'
          '  zoom: 12\n'
          '```\n'
          '\n'
          'Closing paragraph.';
      final matches = findSynapseAppBlocks(source).toList();
      expect(matches, hasLength(1));
      expect(matches.first.body.isValid, isTrue);
      expect(matches.first.body.appUuid, 'my-uuid');
      expect(matches.first.body.params['zoom'], 12);
      expect(source.substring(matches.first.startOffset, matches.first.endOffset),
          contains('```synapse-app'));
    });

    test('finds multiple blocks and preserves order', () {
      const source =
          '```synapse-app\napp: a\n```\n\n'
          'Middle text.\n\n'
          '```synapse-app\napp: b\n```';
      final matches = findSynapseAppBlocks(source).toList();
      expect(matches, hasLength(2));
      expect(matches[0].body.appUuid, 'a');
      expect(matches[1].body.appUuid, 'b');
      expect(matches[0].startOffset, lessThan(matches[1].startOffset));
    });

    test('returns no matches when source has no blocks', () {
      const source = 'No embedded app blocks here.';
      final matches = findSynapseAppBlocks(source).toList();
      expect(matches, isEmpty);
    });
  });

  group('reserved query keys', () {
    test('includes note, notes, revision, and block ref marker', () {
      expect(synapseAppReservedQueryKeys, contains('note'));
      expect(synapseAppReservedQueryKeys, contains('notes'));
      expect(synapseAppReservedQueryKeys, contains('revision'));
      expect(synapseAppReservedQueryKeys, contains(synapseAppBlockRefKey));
    });
  });

  group('isSynapseAppUri', () {
    test('accepts app URIs', () {
      expect(isSynapseAppUri('synapseresource://app/some-uuid'), isTrue);
      expect(
        isSynapseAppUri('synapseresource://app/some-uuid?note=current'),
        isTrue,
      );
    });

    test('rejects other synapseresource types', () {
      expect(isSynapseAppUri('synapseresource://note/abc'), isFalse);
      expect(
        isSynapseAppUri('synapseresource://attachment/abc'),
        isFalse,
      );
    });

    test('rejects non-synapseresource URIs', () {
      expect(isSynapseAppUri('https://example.com'), isFalse);
      expect(isSynapseAppUri(''), isFalse);
    });
  });
}
