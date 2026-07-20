import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const contribRoot = 'contrib/table-studio';
  const pluginRoot = '$contribRoot/plugins';
  const yamlPath = '$pluginRoot/Table_Studio.yaml';
  const sourcePath = '$pluginRoot/table_studio.html';
  const corePath = '$pluginRoot/src/table_core.js';
  const vendorPath = '$pluginRoot/vendor/xlsx-0.20.3.full.min.js';

  group('Table Studio contrib app', () {
    late String source;
    late String core;
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
      'installable YAML exactly matches source with core and SheetJS inline',
      () {
        final expected = source
            .replaceFirst(
              '  <script src="src/table_core.js"></script>',
              inlined(core),
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
              'The installable app must not require a CDN or local sidecar.',
        );
      },
    );

    test('vendors the reviewed SheetJS CE 0.20.3 distribution', () {
      expect(
        sha256.convert(File(vendorPath).readAsBytesSync()).toString(),
        'cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41',
      );
      expect(File('$pluginRoot/vendor/LICENSE.sheetjs').existsSync(), isTrue);
      expect(File('$contribRoot/LICENSE').existsSync(), isTrue);
    });

    test('uses only the required local Synapse capabilities', () {
      final appCode = '$source\n$core';
      for (final requiredApi in [
        'Synapse.Notes',
        '.exportNotes(',
        '.readAttachment(',
        '.updateNotes(',
        // Used for a fresh read of note content right before saving, so a
        // note edited elsewhere since launch is not clobbered.
        '.runQuery(',
      ]) {
        expect(appCode, contains(requiredApi), reason: 'Missing $requiredApi');
      }

      for (final forbiddenCapability in [
        'proxyFetch',
        'originFetch',
        'chatAI',
        'deleteNotes',
        'saveNotes',
        'downloadFile',
        'requestLogin',
        'getCookies',
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
      expect(source, contains('Save copy as .xlsx'));
      // Formula flattening is disclosed before it happens.
      expect(source, contains('formulas become plain values'));
      // Oversized inputs are refused instead of truncated, with the size
      // ceilings enforced BEFORE any rows-x-cols amplification.
      expect(source, contains('MAX_ATTACHMENT_BYTES'));
      expect(source, contains('SIZE_LIMITS'));
      expect(core, contains('maxCells'));
      expect(source, contains('decode_range'));
      // A failed fresh-content read aborts the save instead of falling back
      // to a stale snapshot that would clobber concurrent edits.
      expect(source, contains('strict: true'));
      // Workbook saves patch only edited cells (copy-on-write, committed
      // only after a successful upload) so untouched formulas, types, and
      // formats survive and a failed upload leaves the workbook pristine.
      expect(source, contains('function patchedWorksheetCopy'));
      expect(source, contains('out.commit()'));
      // CSV fidelity metadata survives the round trip.
      expect(core, contains('trailingNewline'));
      expect(core, contains('hadBom'));
      expect(core, contains('arities'));
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
