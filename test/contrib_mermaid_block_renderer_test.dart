import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const pluginRoot = 'contrib/mermaid-block-renderer/plugins';
  const yamlPath = '$pluginRoot/Mermaid_Block_Renderer.yaml';
  const starterYamlPath = 'assets/starter/apps/Mermaid_Block_Renderer.yaml';
  const sourcePath = '$pluginRoot/mermaid_block_renderer.html';

  group('Mermaid Block Renderer app', () {
    late String source;
    late YamlMap manifest;
    late String embeddedHtml;

    setUpAll(() {
      source = File(sourcePath).readAsStringSync();
      manifest = loadYaml(File(yamlPath).readAsStringSync()) as YamlMap;
      embeddedHtml = utf8.decode(base64Decode(manifest['code'] as String));
    });

    test('has installable note-action metadata', () {
      expect(manifest['name'], 'Mermaid Block Renderer');
      expect(manifest['uuid'], '6f3a9c21-0d4e-4b7a-9c58-2e1f7b83a4d6');
      expect(manifest['app_type'], 'note_action');
      expect(manifest['license'], isNotEmpty);
      expect(manifest['author'], isNotEmpty);
      expect(manifest['description'], isNotEmpty);
    });

    test('does not collide with the existing Mermaid ai_tool app', () {
      final other =
          loadYaml(File('assets/starter/apps/Mermaid.yaml').readAsStringSync())
              as YamlMap;
      expect(other['app_type'], 'ai_tool');
      expect(manifest['uuid'], isNot(other['uuid']));
      expect(manifest['name'], isNot(other['name']));
    });

    test('installable YAML matches the readable source exactly', () {
      expect(embeddedHtml, source);
      expect(embeddedHtml, startsWith('<!DOCTYPE html>'));
    });

    test('bundled starter app is the same build', () {
      expect(
        File(starterYamlPath).readAsStringSync(),
        File(yamlPath).readAsStringSync(),
        reason:
            'assets/starter/apps/Mermaid_Block_Renderer.yaml must be '
            'regenerated (plugins/build.sh, then copy) whenever the plugin '
            'changes.',
      );
    });

    test('loads mermaid from the bundled asset, never a CDN', () {
      expect(embeddedHtml, contains('src="synapse://mermaid.min.js"'));
      expect(embeddedHtml, isNot(contains('cdn.jsdelivr')));
      expect(embeddedHtml, isNot(contains('unpkg.com')));
      expect(
        RegExp(r'<script[^>]+src\s*=\s*"https?:').hasMatch(embeddedHtml),
        isFalse,
        reason: 'The app must boot offline from bundled assets.',
      );
    });

    test('writes back through the block-scoped updateNotes contract', () {
      // Targets the transient block note id it was handed...
      expect(embeddedHtml, contains('id: note.id'));
      // ...and replaces the block with image + original source, so a
      // re-render swaps the image instead of stacking a second one.
      expect(embeddedHtml, contains("action: 'replace'"));
      expect(embeddedHtml, contains('stripLeadingImages'));
      // The rendered SVG goes through saveTemp, which the host then promotes
      // to a permanent attachment on the parent note.
      expect(embeddedHtml, contains("Synapse.saveTemp"));
      expect(embeddedHtml, contains("'image/svg+xml'"));
      expect(embeddedHtml, contains('Synapse.updateNotes'));
    });

    test('handles a missing or empty note selection instead of throwing', () {
      expect(embeddedHtml, contains('if (!notes.length)'));
      expect(embeddedHtml, contains('No Mermaid diagram found'));
    });

    test('refuses to run on a whole note, only on a block', () {
      // A whole-note write does NOT promote the synapsetemp SVG to an
      // attachment, so the image would break once the OS purges its cache.
      expect(embeddedHtml, contains('if (!note.isBlockScope)'));
      expect(embeddedHtml, contains('not on a whole note'));
    });

    test('reports a refused write rather than claiming success', () {
      // updateNotes returns success with updatedCount 0 when the host refused
      // the splice (e.g. the block moved), which must not look like a win.
      expect(embeddedHtml, contains('response.updatedCount'));
      expect(embeddedHtml, contains('reselect the block'));
    });
  });

  group('mermaid extraction logic', () {
    // Mirrors extractDiagram()/stripLeadingImages() in the plugin so the
    // regexes are covered by Dart tests the way other contrib apps are.
    // Matched on the plugin's OWN alt text only: stripping any leading image
    // would delete the user's content, because a block selection can be
    // expanded upwards to include a preceding image and the write replaces the
    // whole span.
    String stripLeadingImages(String text) =>
        text.replaceFirst(RegExp(r'^(?:\s*!\[mermaid\]\([^)]*\)\s*)+'), '');

    String extractDiagram(String text) {
      final fenced = RegExp(
        r'```[ \t]*mermaid[ \t]*\r?\n([\s\S]*?)```',
        caseSensitive: false,
      ).firstMatch(text);
      if (fenced != null) return fenced.group(1)!.trim();
      final anyFence = RegExp(r'```[ \t]*\r?\n([\s\S]*?)```').firstMatch(text);
      if (anyFence != null) return anyFence.group(1)!.trim();
      return text.trim();
    }

    test('extracts from a mermaid fence', () {
      expect(
        extractDiagram('```mermaid\ngraph TD\nA --> B\n```'),
        'graph TD\nA --> B',
      );
    });

    test('extracts from an unlabelled fence', () {
      expect(
        extractDiagram('```\ngraph TD\nA --> B\n```'),
        'graph TD\nA --> B',
      );
    });

    test('falls back to raw text with no fence', () {
      expect(extractDiagram('  graph TD\nA --> B  '), 'graph TD\nA --> B');
    });

    test('strips a previously inserted image so re-render is idempotent', () {
      const block =
          '![mermaid](synapsetemp:///old.svg)\n\n```mermaid\ngraph TD\nA --> B\n```';
      final stripped = stripLeadingImages(block);
      expect(stripped, '```mermaid\ngraph TD\nA --> B\n```');
      expect(extractDiagram(stripped), 'graph TD\nA --> B');
      // Stripping twice is stable.
      expect(stripLeadingImages(stripped), stripped);
    });

    test("never strips an image that is not this app's own render", () {
      // A user can expand the block selection upwards to include their own
      // image; the insert replaces the whole span, so stripping it here would
      // silently and unrecoverably delete their content.
      const block =
          '![my screenshot](attachments/shot.png)\n\n'
          '```mermaid\ngraph TD\nA --> B\n```';
      expect(stripLeadingImages(block), block);
      expect(extractDiagram(stripLeadingImages(block)), 'graph TD\nA --> B');
    });

    test("strips its own render even when a user image follows it", () {
      const block =
          '![mermaid](synapsetemp:///old.svg)\n\n'
          '![my screenshot](attachments/shot.png)\n\n'
          '```mermaid\ngraph TD\n```';
      final stripped = stripLeadingImages(block);
      expect(stripped, contains('![my screenshot](attachments/shot.png)'));
      expect(stripped, isNot(contains('old.svg')));
    });

    test('leaves a trailing image alone', () {
      const block = '```mermaid\ngraph TD\n```\n\n![keep](x.png)';
      expect(stripLeadingImages(block), block);
    });
  });
}
