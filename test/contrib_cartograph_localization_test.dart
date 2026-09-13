import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const pluginRoot = 'contrib/cartograph/plugins';
  const apps = ['Cartograph.yaml', 'Cartograph_This_Note.yaml'];

  group('Cartograph localized contrib apps', () {
    final manifests = <YamlMap>[];
    final pages = <String>[];

    setUpAll(() {
      for (final file in apps) {
        final manifest =
            loadYaml(File('$pluginRoot/$file').readAsStringSync()) as YamlMap;
        manifests.add(manifest);
        pages.add(utf8.decode(base64Decode(manifest['code'] as String)));
      }
    });

    test('both launch types ship Simplified Chinese metadata', () {
      for (final manifest in manifests) {
        expect(manifest['i18n']['zh-CN']['name'], isNotEmpty);
        expect(manifest['i18n']['zh-CN']['description'], isNotEmpty);
      }
      expect(
        manifests[0]['i18n']['zh-CN']['name'],
        isNot(manifests[1]['i18n']['zh-CN']['name']),
      );
    });

    test('one self-contained page handles live locale changes', () {
      expect(manifests[0]['code'], manifests[1]['code']);
      for (final page in pages) {
        expect(page, contains('CG.i18n'));
        expect(page, contains('Synapse.locale'));
        expect(page, contains('synapse:localechanged'));
        expect(
          RegExp(r'<script[^>]+\bsrc\s*=', caseSensitive: false).hasMatch(page),
          isFalse,
        );
      }
    });

    test('bundled starter manifests are identical', () {
      for (final file in apps) {
        expect(
          File('assets/starter/apps/$file').readAsStringSync(),
          File('$pluginRoot/$file').readAsStringSync(),
        );
      }
    });
  });
}
