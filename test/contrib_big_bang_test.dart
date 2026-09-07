import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const contribRoot = 'contrib/big-bang';
  const pluginRoot = '$contribRoot/plugins';
  const sourcePath = '$pluginRoot/big-bang.html';

  // In load order, which is the order the shell lists them in and the order
  // build.sh inlines them: board.js first, because every other module reads
  // its coercions at load time.
  const moduleNames = <String>[
    'src/board.js',
    'src/model.js',
    'src/host.js',
    'src/notes.js',
    'src/render.js',
    'src/gestures.js',
    'src/ai.js',
    'src/export.js',
    'src/app.js',
  ];

  // One HTML, emitted twice. A `normal` launch arrives with no note and shows
  // the board home; a `note_action` launch arrives with one note and opens it
  // as the canvas, or with several and makes a new board holding all of them.
  // The app tells them apart at runtime, so the two YAMLs differ only in their
  // name, uuid and app_type.
  const apps = <Map<String, String>>[
    {
      'file': 'Big_Bang.yaml',
      'name': 'Big Bang',
      'uuid': '9f6001dd-661d-4aa7-ba18-c54164b94338',
      'type': 'normal',
    },
    {
      'file': 'Big_Bang_This_Note.yaml',
      'name': 'Big Bang: this note',
      'uuid': '51c3806d-b1e4-4fd4-b1ac-bb58124afef7',
      'type': 'note_action',
    },
  ];

  group('Big Bang contrib app', () {
    late String source;
    final files = <String, String>{};
    final manifests = <String, YamlMap>{};
    final html = <String, String>{};

    String inlined(String script) {
      final escaped = script.replaceAll('</script>', r'<\/script>');
      return '  <script>\n$escaped\n  </script>';
    }

    setUpAll(() {
      source = File(sourcePath).readAsStringSync();
      for (final name in moduleNames) {
        files[name] = File('$pluginRoot/$name').readAsStringSync();
      }
      for (final app in apps) {
        final file = app['file']!;
        final manifest =
            loadYaml(File('$pluginRoot/$file').readAsStringSync()) as YamlMap;
        manifests[file] = manifest;
        html[file] = utf8.decode(base64Decode(manifest['code'] as String));
      }
    });

    test('both installable apps carry the metadata the host reads', () {
      for (final app in apps) {
        final file = app['file']!;
        final manifest = manifests[file]!;
        expect(manifest['name'], app['name'], reason: file);
        expect(manifest['uuid'], app['uuid'], reason: file);
        expect(manifest['app_type'], app['type'], reason: file);
        expect(manifest['license'], 'Apache-2.0', reason: file);
        expect(manifest['author'], isNotEmpty, reason: file);
        expect(manifest['description'], isNotEmpty, reason: file);
        expect(html[file], startsWith('<!doctype html>'), reason: file);
      }
    });

    test('the two launch types are told apart by uuid and name, not by code', () {
      expect(manifests['Big_Bang.yaml']!['uuid'],
          isNot(manifests['Big_Bang_This_Note.yaml']!['uuid']));
      expect(manifests['Big_Bang.yaml']!['name'],
          isNot(manifests['Big_Bang_This_Note.yaml']!['name']));
      expect(manifests['Big_Bang.yaml']!['app_type'],
          isNot(manifests['Big_Bang_This_Note.yaml']!['app_type']));
      // One source file, emitted twice: a divergence here means one of the two
      // was rebuilt and the other was not.
      expect(
        manifests['Big_Bang.yaml']!['code'],
        manifests['Big_Bang_This_Note.yaml']!['code'],
        reason: 'both apps must ship the same HTML - run plugins/build.sh',
      );
    });

    test('installable YAML exactly matches source with all modules inline', () {
      var expected = source;
      for (final name in moduleNames) {
        final tag = '<script src="$name"></script>';
        expect(
          expected.contains(tag),
          isTrue,
          reason: 'big-bang.html no longer references $name',
        );
        expected = expected.replaceFirst(tag, inlined(files[name]!));
      }
      for (final app in apps) {
        expect(
          html[app['file']!],
          expected,
          reason:
              '${app['file']} is stale - run contrib/big-bang/plugins/build.sh',
        );
      }
    });

    test('the shipped app is self-contained', () {
      for (final app in apps) {
        final file = app['file']!;
        final built = html[file]!;
        // An installed app is one row in a table and has no directory to load
        // a second file from: a <script src> in it is a blank screen on a
        // phone, not an error at build time.
        expect(
          RegExp(r'<script[^>]+\bsrc\s*=', caseSensitive: false)
              .hasMatch(built),
          isFalse,
          reason: '$file still loads an external script',
        );
        expect(
          RegExp(r'<link[^>]+stylesheet', caseSensitive: false).hasMatch(built),
          isFalse,
          reason: '$file still loads an external stylesheet',
        );
        expect(built.contains('src="src/'), isFalse, reason: file);
        expect(built.contains('BB.app.boot()'), isTrue, reason: file);
        // Every literal </script> in the sources has to have been escaped on
        // the way in, or the page ends early and everything after it is body
        // text. The count is only a test while some source really holds one.
        final literals = moduleNames.fold<int>(
          0,
          (n, name) => n + '</script>'.allMatches(files[name]!).length,
        );
        expect(
          literals,
          greaterThan(0),
          reason: 'no source holds a literal </script>, so the check below '
              'proves nothing',
        );
        expect(
          RegExp(r'<\\/script>').allMatches(built).length,
          literals,
          reason: '$file did not escape every literal </script>',
        );
        expect(
          RegExp(r'</script>', caseSensitive: false).allMatches(built).length,
          RegExp(r'<script\b', caseSensitive: false).allMatches(built).length,
          reason: '$file does not close as many script elements as it opens',
        );
      }
    });

    test('uses only the Synapse capabilities it needs', () {
      final built = html['Big_Bang.yaml']!;
      // Matched on the call site: host.js holds the bridge in a local `S`, so
      // the object is not named at most call sites.
      const required = <String>[
        'runQuery',
        'updateNotes',
        'saveNotes',
        'pickNotes',
        'openMerge',
        'openNote',
        // The one AI feature: suggest links. Plain text in, plain text out -
        // there is no schema mode - and the board works with it switched off.
        'chatAI',
      ];
      for (final api in required) {
        expect(built, contains('.$api('), reason: 'Missing $api');
      }
      // A board is geometry over notes that already exist. It never reaches the
      // network, and it never deletes a note - a card leaving the board is not
      // a note leaving the library.
      const forbidden = <String>[
        'proxyFetch',
        'originFetch',
        'downloadFile',
        'fetchWebPage',
        'deleteNotes',
        'requestLogin',
        'getCookies',
      ];
      for (final api in forbidden) {
        expect(built, isNot(contains(api)), reason: 'Unexpected capability: $api');
      }
    });

    test('keeps the note-safety contract', () {
      final host = files['src/host.js']!;
      final board = files['src/board.js']!;

      // Every save re-reads the note and splices only its own fenced block
      // into the fresh text, and a failed read aborts rather than writing back
      // a remembered copy.
      expect(host, contains('SELECT id, content, length(content) AS clen'));
      expect(host, contains("reason: 'read-failed'"));
      // A block written by a newer version, a damaged one, or a second one in
      // the same note are refusals, not things to overwrite.
      expect(host, contains("reason: 'conflict'"));
      expect(host, contains("reason: 'malformed'"));
      expect(host, contains("reason: 'extra'"));
      // The board lives in one fenced block; the note's own prose is not the
      // app's to touch.
      expect(board, contains('synapse-bigbang'));

      // Card faces come from a truncated read, never from exportNotes - which
      // returns a rendered share-export with section labels and localised
      // headings, not the note's text. (The name still appears in a comment
      // saying exactly that, so the check is on the CALL.)
      expect(files['src/notes.js']! + host, contains('substr(content'));
      expect(html['Big_Bang.yaml']!, isNot(contains('.exportNotes(')));
    });
  });
}
