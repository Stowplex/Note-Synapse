import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const contribRoot = 'contrib/table-studio';
  const pluginRoot = '$contribRoot/plugins';
  const yamlPath = '$pluginRoot/Table_Studio.yaml';
  const starterYamlPath = 'assets/starter/apps/Table_Studio.yaml';
  const sourcePath = '$pluginRoot/table_studio.html';
  const corePath = '$pluginRoot/src/table_core.js';
  const bridgePath = '$pluginRoot/src/univer_bridge.js';
  const fflatePath = '$pluginRoot/vendor/fflate-0.8.2.min.js';
  const vendorPath = '$pluginRoot/vendor/xlsx-0.20.3.full.min.js';

  group('Table Studio contrib app', () {
    late String source;
    late String core;
    late String bridge;
    late String fflate;
    late String vendor;
    late String embeddedHtml;
    late YamlMap manifest;

    String inlined(String script) {
      final escaped = script.replaceAll('</script>', r'<\/script>');
      return '  <script>\n$escaped\n  </script>';
    }

    setUpAll(() {
      source = File(sourcePath).readAsStringSync();
      core = File(corePath).readAsStringSync();
      bridge = File(bridgePath).readAsStringSync();
      fflate = File(fflatePath).readAsStringSync();
      vendor = File(vendorPath).readAsStringSync();
      manifest = loadYaml(File(yamlPath).readAsStringSync()) as YamlMap;
      embeddedHtml = utf8.decode(base64Decode(manifest['code'] as String));
    });

    test('has installable note-action metadata', () {
      expect(manifest['name'], 'Table Studio');
      expect(manifest['uuid'], '054e7289-7008-4be5-a865-a9fd8d77f09c');
      expect(manifest['app_type'], 'note_action');
      expect(manifest['license'], 'Apache-2.0');
      expect(manifest['author'], isNotEmpty);
      expect(manifest['description'], isNotEmpty);
      expect(embeddedHtml, startsWith('<!doctype html>'));
    });

    test(
      'installable YAML exactly matches source with all modules inline',
      () {
        final expected = source
            .replaceFirst(
              '  <script src="src/table_core.js"></script>',
              inlined(core),
            )
            .replaceFirst(
              '  <script src="src/univer_bridge.js"></script>',
              inlined(bridge),
            )
            .replaceFirst(
              '  <script src="vendor/fflate-0.8.2.min.js"></script>',
              inlined(fflate),
            )
            .replaceFirst(
              '  <script src="vendor/xlsx-0.20.3.full.min.js"></script>',
              inlined(vendor),
            );

        expect(embeddedHtml, expected);
        expect(
          RegExp(
            r'<script[^>]+\bsrc\s*=',
            caseSensitive: false,
          ).hasMatch(embeddedHtml),
          isFalse,
          reason:
              'The installable app must boot without a CDN or local sidecar '
              '(the Univer engine is fetched at runtime, sha256-pinned).',
        );
      },
    );

    test('bundled starter app is the same build', () {
      expect(
        File(starterYamlPath).readAsStringSync(),
        File(yamlPath).readAsStringSync(),
        reason: 'assets/starter/apps/Table_Studio.yaml must be regenerated '
            '(plugins/build.sh, then copy) whenever the plugin changes.',
      );
    });

    test('vendors the reviewed SheetJS CE 0.20.3 distribution', () {
      expect(
        sha256.convert(File(vendorPath).readAsBytesSync()).toString(),
        'cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41',
      );
      expect(File('$pluginRoot/vendor/LICENSE.sheetjs').existsSync(), isTrue);
      expect(File('$contribRoot/LICENSE').existsSync(), isTrue);
    });

    test('vendors the reviewed fflate 0.8.2 distribution', () {
      expect(
        sha256.convert(File(fflatePath).readAsBytesSync()).toString(),
        'c3b34f2e9f5e74d4d7d64e01cac7a0c01954c6c406414d42185c7b53d6875ddf',
      );
      expect(File('$pluginRoot/vendor/LICENSE.fflate').existsSync(), isTrue);
    });

    test('engine downloads are pinned to public npm mirrors by sha256', () {
      // The only network the app touches is the Univer engine download; it
      // must go to the two well-known npm CDNs and be content-addressed.
      expect(
        bridge,
        contains("'https://cdn.jsdelivr.net/npm/'"),
      );
      expect(bridge, contains("'https://unpkg.com/'"));
      final mirrors = RegExp(r"https?://[^'\s]+").allMatches(bridge).map(
            (m) => m.group(0)!,
          );
      for (final url in mirrors) {
        expect(
          url.startsWith('https://cdn.jsdelivr.net/npm/') ||
              url.startsWith('https://unpkg.com/'),
          isTrue,
          reason: 'Unexpected engine host: $url',
        );
      }
      // Every manifest entry carries a 64-hex sha256 pin.
      final shaPins = RegExp(r"sha256: '([0-9a-f]{64})'").allMatches(bridge);
      final paths = RegExp(r"path: '").allMatches(bridge);
      expect(shaPins.length, paths.length);
      expect(shaPins.length, greaterThanOrEqualTo(20));
      // The downloader refuses unverifiable or mismatching payloads, and a
      // host without download/verify support is refused up front.
      expect(source, contains("crypto.digest('sha256'"));
      expect(source, contains('checksum mismatch'));
      expect(source, contains('engineHostReady'));
      // And no other proxyFetch call sites exist in the app.
      expect(
        'Synapse.proxyFetch('.allMatches(source).length,
        1,
        reason: 'proxyFetch must only be called by the engine downloader',
      );
    });

    test('uses only the required local Synapse capabilities', () {
      final appCode = '$source\n$core\n$bridge';
      for (final requiredApi in [
        'Synapse.Notes',
        '.exportNotes(',
        '.readAttachment(',
        '.updateNotes(',
        // Used for a fresh read of note content right before saving, so a
        // note edited elsewhere since launch is not clobbered.
        '.runQuery(',
        // Engine cache (download once, then offline).
        '.loadAppState(',
        '.storeAppState(',
      ]) {
        expect(appCode, contains(requiredApi), reason: 'Missing $requiredApi');
      }

      for (final forbiddenCapability in [
        'originFetch',
        'chatAI',
        'deleteNotes',
        'saveNotes',
        'downloadFile',
        'requestLogin',
        'getCookies',
        'session: true',
        'document.cookie',
        'localStorage.',
        'innerHTML',
        'insertAdjacentHTML',
        'eval(',
        'new Function',
      ]) {
        expect(
          appCode,
          isNot(contains(forbiddenCapability)),
          reason: 'Unexpected capability: $forbiddenCapability',
        );
      }
    });

    test('keeps the data-safety contract', () {
      // Markdown tables are re-located in fresh content before overwriting.
      expect(source, contains('fetchNoteContent'));
      expect(source, contains("action: 'replace'"));
      expect(
        source,
        contains('The note changed since this table was opened'),
      );
      // Legacy Excel formats are never rewritten in place.
      expect(source, contains("xls: { mode: 'workbook-ro' }"));
      expect(source, contains("xlsm: { mode: 'workbook-ro' }"));
      expect(source, contains('Save copy'));
      // Formula/merge flattening (markdown/CSV targets) is disclosed and
      // confirmed before it happens.
      expect(source, contains('Sheet features become plain cells'));
      // Number formats are only preserved if SheetJS is told to read them.
      expect(source, contains('cellNF: true'));
      // Oversized inputs are refused instead of truncated, with the size
      // ceilings enforced BEFORE any rows-x-cols amplification.
      expect(source, contains('MAX_ATTACHMENT_BYTES'));
      expect(source, contains('SIZE_LIMITS'));
      expect(core, contains('maxCells'));
      expect(source, contains('decode_range'));
      // A failed fresh-content read aborts the save instead of falling back
      // to a stale snapshot that would clobber concurrent edits.
      expect(source, contains('strict: true'));
      // Workbook saves: untouched sheets are carried byte-identical, and
      // sheets without structural edits are cell-diff patched (copy-on-write,
      // committed only after a successful upload) so untouched formulas,
      // types and formats survive.
      expect(bridge, contains('function patchWorksheet'));
      expect(bridge, contains('function normalizedToWorksheet'));
      expect(source, contains('out.commit()'));
      expect(source, contains('isStructuralMutation'));
      // Downloaded engine bytes are verified before they execute.
      expect(source, contains('checksum mismatch'));
      // CSV fidelity metadata survives the round trip.
      expect(core, contains('trailingNewline'));
      expect(core, contains('hadBom'));
      expect(core, contains('arities'));
      // Numeric coercion never changes a cell's spelling on save.
      expect(bridge, contains('function stableNumber'));
      // Non-UTF-8 files are refused, never decoded lossily.
      expect(source, contains('fatal: true'));
      // Tables inside fenced code blocks are ignored by the scanner.
      expect(core, contains('FENCE_RE'));
    });

    test('reviewed capability surface for note updates', () {
      // Attachment saves replace the old file in a single update call.
      expect(source, contains("attachments: { added: [payload], removed: [] }"));
      // The update result is verified, not assumed.
      expect(source, contains('interpretUpdateResult'));
      expect(source, contains('updatedCount > 0'));
    });
  });
}
