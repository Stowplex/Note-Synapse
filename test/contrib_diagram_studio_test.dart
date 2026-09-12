import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const contribRoot = 'contrib/diagram-studio';
  const pluginRoot = '$contribRoot/plugins';
  const yamlPath = '$pluginRoot/Diagram_Studio.yaml';
  const starterYamlPath = 'assets/starter/apps/Diagram_Studio.yaml';
  const sourcePath = '$pluginRoot/diagram_studio.html';

  // Order matters: it must match the order the modules appear in the HTML.
  const moduleNames = <String>[
    'src/i18n.js',
    'src/blocks.js',
    'src/writeback.js',
    'src/raster.js',
    'src/render_mermaid.js',
    'src/render_ascii.js',
    'src/draw.js',
    'src/ai.js',
  ];
  const vendorNames = <String>[
    'vendor/js-draw-1.33.0.styles.js',
    'vendor/js-draw-1.33.0.bundle.js',
  ];

  // Pinned so a swapped-in vendor file cannot slip through review unnoticed.
  const vendorSha = <String, String>{
    'vendor/js-draw-1.33.0.bundle.js':
        '8d33958f0dfea20402507ce8a94331952ceb81141d3423a021171d49d60d52ba',
    'vendor/js-draw-1.33.0.styles.js':
        'a3609b645a336210cd5a19ef2b38ac2da3461b720cc96af018b5386bd79530b3',
  };

  group('Diagram Studio contrib app', () {
    late String source;
    late String embeddedHtml;
    late YamlMap manifest;
    final files = <String, String>{};

    String inlined(String script) {
      final escaped = script.replaceAll('</script>', r'<\/script>');
      return '  <script>\n$escaped\n  </script>';
    }

    setUpAll(() {
      source = File(sourcePath).readAsStringSync();
      for (final name in [...moduleNames, ...vendorNames]) {
        files[name] = File('$pluginRoot/$name').readAsStringSync();
      }
      manifest = loadYaml(File(yamlPath).readAsStringSync()) as YamlMap;
      embeddedHtml = utf8.decode(base64Decode(manifest['code'] as String));
    });

    test('has installable note-action metadata', () {
      expect(manifest['name'], 'Diagram Studio');
      expect(manifest['uuid'], 'b7c41e58-93a2-4d6f-8e15-0af3c962d7b4');
      expect(manifest['app_type'], 'note_action');
      expect(manifest['license'], 'Apache-2.0');
      expect(manifest['author'], isNotEmpty);
      expect(manifest['description'], isNotEmpty);
      expect(manifest['i18n']['zh-CN']['name'], '图表工作室');
      expect(manifest['i18n']['zh-CN']['description'], isNotEmpty);
      expect(embeddedHtml, startsWith('<!DOCTYPE html>'));
    });

    test('does not collide with the other bundled diagram apps', () {
      final other =
          loadYaml(File('assets/starter/apps/Mermaid.yaml').readAsStringSync())
              as YamlMap;
      expect(other['app_type'], 'ai_tool');
      expect(manifest['uuid'], isNot(other['uuid']));
      expect(manifest['name'], isNot(other['name']));
    });

    test('installable YAML exactly matches source with all modules inline', () {
      var expected = source;
      for (final name in [...moduleNames, ...vendorNames]) {
        final tag = RegExp(
          '^.*<script[^>]*src="${RegExp.escape(name)}"[^>]*></script>.*\$',
          multiLine: true,
        );
        expect(
          tag.hasMatch(expected),
          isTrue,
          reason: 'diagram_studio.html no longer references $name',
        );
        expected = expected.replaceFirst(tag, inlined(files[name]!));
      }
      expect(embeddedHtml, expected);
    });

    test('boots offline from bundled assets only', () {
      // Mermaid comes from the app's own asset, never a CDN.
      expect(embeddedHtml, contains('src="synapse://mermaid.min.js"'));

      // synapse:// is the ONLY script src permitted in the shipped app: a
      // local sidecar that failed to inline would build cleanly and then be
      // unable to load its library on a device.
      final srcs = RegExp(
        r'<script[^>]+\bsrc\s*=\s*"([^"]*)"',
        caseSensitive: false,
      ).allMatches(embeddedHtml).map((m) => m.group(1)!).toList();
      expect(srcs, isNotEmpty);
      for (final src in srcs) {
        expect(
          src,
          startsWith('synapse://'),
          reason: 'Unexpected script source in the installable app: $src',
        );
      }

      expect(embeddedHtml, isNot(contains('cdn.jsdelivr')));
      expect(embeddedHtml, isNot(contains('unpkg.com/js-draw')));
    });

    test('vendors the reviewed js-draw distribution', () {
      for (final entry in vendorSha.entries) {
        final bytes = File('$pluginRoot/${entry.key}').readAsBytesSync();
        expect(
          sha256.convert(bytes).toString(),
          entry.value,
          reason: '${entry.key} does not match the reviewed distribution',
        );
      }
      expect(File('$pluginRoot/vendor/LICENSE.js-draw').existsSync(), isTrue);
      expect(File('$contribRoot/LICENSE').existsSync(), isTrue);
      expect(embeddedHtml, contains('var jsdraw='));
    });

    test('the vendored bundle makes no network calls of its own', () {
      final bundle = files['vendor/js-draw-1.33.0.bundle.js']!;
      expect(bundle, isNot(contains('XMLHttpRequest')));
      expect(bundle, isNot(contains('importScripts')));
      expect(bundle, isNot(contains('@font-face')));
      // The only http(s) strings may be the SVG namespace and attribution.
      final urls = RegExp(
        r'https?://[a-zA-Z0-9./_-]+',
      ).allMatches(bundle).map((m) => m.group(0)!).toSet();
      for (final url in urls) {
        expect(
          url.startsWith('http://www.w3.org/') ||
              url.startsWith('https://github.com/'),
          isTrue,
          reason: 'Unexpected URL in the vendored bundle: $url',
        );
      }
    });

    test('bundled starter app is the same build', () {
      expect(
        File(starterYamlPath).readAsStringSync(),
        File(yamlPath).readAsStringSync(),
        reason:
            'assets/starter/apps/Diagram_Studio.yaml must be regenerated '
            '(plugins/build.sh, then copy) whenever the plugin changes.',
      );
    });

    test('uses only the Synapse capabilities it needs', () {
      // Matched on the call site rather than a `Synapse.` prefix: the modules
      // receive the bridge by injection (`S.updateNotes(...)`) so the object
      // is not named at most call sites.
      const required = <String>[
        'updateNotes',
        'exportNotes',
        'saveTemp',
        'readAttachment',
        'runQuery',
        'chatAI',
        'storeAppState',
        'loadAppState',
      ];
      for (final api in required) {
        expect(embeddedHtml, contains('.$api('), reason: 'Missing $api');
      }

      // This app has no business reaching the network or deleting anything.
      // Bare names, so a call through an injected reference cannot hide.
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
        expect(
          embeddedHtml,
          isNot(contains(api)),
          reason: 'Unexpected capability: $api',
        );
      }
    });

    test('keeps the note-safety contract', () {
      final blocks = files['src/blocks.js']!;
      final writeback = files['src/writeback.js']!;

      // Renders are recognised by a typed alt text, and the legacy alt written
      // by Mermaid Block Renderer must stay recognised forever or an upgraded
      // note grows a second image on its first re-render.
      expect(blocks, contains('diagram(?::[a-z-]+)?|mermaid'));

      // Whole-note saves re-read raw content before replacing, and a failed
      // read aborts rather than writing back a stale snapshot.
      expect(writeback, contains('SELECT content FROM notes'));
      expect(writeback, contains('Could not re-read the note before saving'));

      // Block scope must not try to attach through the block id.
      expect(writeback, contains('attachmentNoteId'));

      // Only attachments this app wrote may be collected.
      expect(writeback, contains('attachments = { removed: stale }'));
    });

    test('the retired Mermaid Block Renderer is no longer bundled', () {
      expect(
        File('assets/starter/apps/Mermaid_Block_Renderer.yaml').existsSync(),
        isFalse,
        reason:
            'Diagram Studio replaces it; existing installs keep their own '
            'copy in the database, so removing the starter asset is the whole '
            'retirement.',
      );
      expect(Directory('contrib/mermaid-block-renderer').existsSync(), isFalse);
    });
  });
}
