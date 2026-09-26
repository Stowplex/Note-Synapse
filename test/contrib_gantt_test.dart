import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const contribRoot = 'contrib/gantt';
  const pluginRoot = '$contribRoot/plugins';
  const sourcePath = '$pluginRoot/gantt.html';

  // D18 load order: the order the shell lists them in and the order build.sh
  // inlines them (its MODULES).
  const moduleNames = <String>[
    'src/i18n.js',
    'src/dates.js',
    'src/model.js',
    'src/undo.js',
    'src/block.js',
    'src/md.js',
    'src/host.js',
    'src/store.js',
    'src/scale.js',
    'src/layout.js',
    'src/theme.js',
    'src/render.js',
    'src/gestures.js',
    'src/sheet.js',
    'src/exporter.js',
    'src/app.js',
  ];

  // One HTML, emitted twice. A `normal` launch shows the chart list; a
  // `note_action` launch opens the selected note as a chart or offers the
  // charts that contain it. The uuids were generated once and never change.
  const apps = <Map<String, String>>[
    {
      'file': 'Gantt.yaml',
      'name': 'Gantt',
      'zh': '甘特图',
      'uuid': 'aac1665f-3f18-425c-a2f5-6e6001d75326',
      'type': 'normal',
    },
    {
      'file': 'Gantt_This_Note.yaml',
      'name': 'Gantt: this note',
      'zh': '甘特图：当前笔记',
      'uuid': '2d96f7fe-b846-4eda-9ab8-81a1b8735fe8',
      'type': 'note_action',
    },
  ];

  group('Gantt contrib app', () {
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
        expect(manifest['author'], 'Bruce Li', reason: file);
        expect(manifest['description'], isNotEmpty, reason: file);
        expect(manifest['i18n']['zh-CN']['name'], app['zh'], reason: file);
        expect(
          manifest['i18n']['zh-CN']['description'],
          isNotEmpty,
          reason: file,
        );
        expect(html[file], startsWith('<!doctype html>'), reason: file);
      }
    });

    test('build.sh inlines the same modules in the same order', () {
      final build = File('$pluginRoot/build.sh').readAsStringSync();
      final match = RegExp(r'\nMODULES=\(([^)]*)\)').firstMatch(build);
      expect(match, isNotNull);
      expect(
        match!.group(1)!.trim().split(RegExp(r'\s+')),
        moduleNames
            .map((n) => n.replaceFirst('src/', '').replaceFirst('.js', ''))
            .toList(),
      );
    });

    test('the two launch types differ by uuid, name and type, not code', () {
      final a = manifests['Gantt.yaml']!;
      final b = manifests['Gantt_This_Note.yaml']!;
      expect(a['uuid'], isNot(b['uuid']));
      expect(a['name'], isNot(b['name']));
      expect(a['app_type'], isNot(b['app_type']));
      expect(
        a['code'],
        b['code'],
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
          reason: 'gantt.html no longer references $name',
        );
        expected = expected.replaceFirst(tag, inlined(files[name]!));
      }
      for (final app in apps) {
        expect(
          html[app['file']!],
          expected,
          reason:
              '${app['file']} is stale - run contrib/gantt/plugins/build.sh',
        );
      }
    });

    test('the shipped app is self-contained', () {
      for (final app in apps) {
        final file = app['file']!;
        final built = html[file]!;
        expect(
          RegExp(
            r'<script[^>]+\bsrc\s*=',
            caseSensitive: false,
          ).hasMatch(built),
          isFalse,
          reason: '$file still loads an external script',
        );
        expect(
          RegExp(r'<link[^>]+stylesheet', caseSensitive: false).hasMatch(built),
          isFalse,
          reason: '$file still loads an external stylesheet',
        );
        expect(built.contains('import('), isFalse, reason: file);
        // An inline SVG's xmlns may name http://www.w3.org; a resource may not.
        expect(
          RegExp(
            r'''(?:src|href)\s*=\s*["']https?:|url\(\s*["']?https?:''',
            caseSensitive: false,
          ).hasMatch(built),
          isFalse,
          reason: '$file loads something over the network',
        );
        expect(built.contains('src="src/'), isFalse, reason: file);
        expect(built.contains('GT.app.boot();'), isTrue, reason: file);
        // Every literal </script> in the sources must arrive escaped. The
        // count is only a test while some source really holds one.
        final literals = moduleNames.fold<int>(
          0,
          (n, name) => n + '</script>'.allMatches(files[name]!).length,
        );
        expect(literals, greaterThan(0), reason: 'the check below is vacuous');
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

    test('follows the host locale (in code, not comments)', () {
      // Comments are stripped first: a comment naming Synapse.locale would
      // pass a plain contains() while the app ignored the locale.
      String code(String js) => js
          .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
          .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');
      final host = code(files['src/host.js']!);
      final app = code(files['src/app.js']!);
      // host.js reads Synapse.locale through its bound Synapse object `s`.
      expect(host, contains("typeof s.locale === 'string'"));
      expect(host, contains("addEventListener('synapse:' + name"));
      expect(app, contains("H.on('localechanged'"));
      expect(app, contains('I().setLanguage('));
      final built = code(html['Gantt.yaml']!);
      expect(built, contains("typeof s.locale === 'string'"));
      expect(built, contains("H.on('localechanged'"));
    });

    test('GT.APP_UUID is the normal app uuid (the embed line names it)', () {
      final host = files['src/host.js']!;
      final m = RegExp(r"GT\.APP_UUID = '([0-9a-f-]+)'").firstMatch(host);
      expect(m, isNotNull);
      expect(m!.group(1), manifests['Gantt.yaml']!['uuid']);
    });

    test('keeps the note-safety contract', () {
      final host = files['src/host.js']!;
      final built = html['Gantt.yaml']!;
      expect(files['src/block.js']!, contains("B.INFO = 'synapse-gantt'"));
      expect(built, isNot(contains('deleteNotes')));
      expect(
        RegExp(r'''action\s*:\s*['"]replace['"]''').hasMatch(built),
        isFalse,
      );
      expect(host, contains("action: 'replace_text'"));
      expect(RegExp(r'r\.data').hasMatch(host), isTrue);
      expect(RegExp(r'r\.state\b').hasMatch(host), isFalse);
    });
  });
}
