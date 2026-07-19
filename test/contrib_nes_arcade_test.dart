import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const contribRoot = 'contrib/nes-arcade';
  const pluginRoot = '$contribRoot/plugins';
  const yamlPath = '$pluginRoot/Neon_Cartridge.yaml';
  const sourcePath = '$pluginRoot/nes_arcade.html';
  const vendorPath = '$pluginRoot/vendor/jsnes-2.0.0.min.js';

  group('Neon Cartridge contrib app', () {
    late String source;
    late String vendor;
    late String embeddedHtml;
    late YamlMap manifest;

    setUpAll(() {
      source = File(sourcePath).readAsStringSync();
      vendor = File(vendorPath).readAsStringSync();
      manifest = loadYaml(File(yamlPath).readAsStringSync()) as YamlMap;
      embeddedHtml = utf8.decode(base64Decode(manifest['code'] as String));
    });

    test('has installable note-action metadata', () {
      expect(manifest['name'], 'Neon Cartridge');
      expect(manifest['uuid'], '62fc706a-a740-49b0-853f-d5c873994d60');
      expect(manifest['app_type'], 'note_action');
      expect(manifest['license'], 'Apache-2.0');
      expect(embeddedHtml, startsWith('<!doctype html>'));
    });

    test(
      'installable YAML exactly matches source with offline jsnes inline',
      () {
        final escapedVendor = vendor.replaceAll('</script>', r'<\/script>');
        final expected = source.replaceFirst(
          '  <script src="vendor/jsnes-2.0.0.min.js"></script>',
          '  <script>\n$escapedVendor\n  </script>',
        );

        expect(embeddedHtml, expected);
        expect(
          RegExp(
            r'<script[^>]+\bsrc\s*=',
            caseSensitive: false,
          ).hasMatch(embeddedHtml),
          isFalse,
          reason:
              'The installable app must not require a CDN or local sidecar.',
        );
      },
    );

    test('vendors the reviewed jsnes 2.0.0 distribution', () {
      expect(
        sha256.convert(File(vendorPath).readAsBytesSync()).toString(),
        '574f7181c68a3e26fd60744a09e9a7b671d1bc5a6a19f191d7362f10cd76578e',
      );
      expect(File('$pluginRoot/vendor/LICENSE.jsnes').existsSync(), isTrue);
      expect(File('$contribRoot/LICENSE').existsSync(), isTrue);
    });

    test('uses only the required local Synapse capabilities', () {
      for (final requiredApi in [
        'Synapse.Notes',
        'Synapse.readAttachment',
        'Synapse.loadAppState',
        'Synapse.storeAppState',
        'Synapse.saveTemp',
        'Synapse.updateNotes',
      ]) {
        expect(source, contains(requiredApi), reason: 'Missing $requiredApi');
      }

      for (final forbiddenCapability in [
        '__NEON_CARTRIDGE_DIAGNOSTICS__',
        'Synapse.runQuery',
        'Synapse.proxyFetch',
        'Synapse.originFetch',
        'Synapse.chatAI',
        'Synapse.deleteNotes',
        'document.cookie',
        'localStorage.',
        'innerHTML',
        'eval(',
      ]) {
        expect(
          source,
          isNot(contains(forbiddenCapability)),
          reason: 'Unexpected capability: $forbiddenCapability',
        );
      }
    });

    test('keeps rapid controls and the dual screenshot write contract', () {
      expect(source, contains('data-nes-button="TURBO_A"'));
      expect(source, contains('data-nes-button="TURBO_B"'));
      expect(source, contains('BUTTON_TURBO_A'));
      expect(source, contains('BUTTON_TURBO_B'));
      expect(source, contains('content: { action: "append", text: markdown }'));
      expect(
        source,
        contains('attachments: { added: [temp.uri], removed: [] }'),
      );
      expect(source, contains('canvas.toDataURL("image/png")'));
    });

    test('uses the native NES frame and a WebView-safe bounded runtime', () {
      expect(source, contains('aspect-ratio: 256 / 240'));
      expect(source, contains('this.canvas.width = 256'));
      expect(source, contains('this.canvas.height = 240'));
      expect(source, contains('class WebViewAudio'));
      expect(source, contains('createScriptProcessor'));
      expect(source, contains('class NesRuntime'));
      expect(source, contains('Math.min(rawDelta, this.frameInterval * 2)'));
      expect(source, isNot(contains('new window.jsnes.Browser')));
    });

    test('keeps adversarial input and async races bounded', () {
      expect(source, contains('const MAX_ROM_BYTES = 32 * 1024 * 1024'));
      expect(source, contains('const MAX_QUICK_SAVES = 3'));
      expect(source, contains('generation !== state.loadGeneration'));
      expect(source, contains('state.isSavingCapture'));
      expect(source, contains('maxlength="20000"'));
    });
  });
}
