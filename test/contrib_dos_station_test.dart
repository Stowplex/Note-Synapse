import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const pluginRoot = 'contrib/dos-station/plugins';
  const yamlPath = '$pluginRoot/DOS_Station.yaml';
  const sourcePath = '$pluginRoot/dos_station.html';

  group('DOS Station contrib app', () {
    late String source;
    late String embeddedHtml;
    late YamlMap manifest;

    setUpAll(() {
      source = File(sourcePath).readAsStringSync();
      manifest = loadYaml(File(yamlPath).readAsStringSync()) as YamlMap;
      embeddedHtml = utf8.decode(base64Decode(manifest['code'] as String));
    });

    test('has installable note-action metadata', () {
      expect(manifest['name'], 'DOS Station');
      expect(manifest['uuid'], '282d85c5-82cd-4d0f-b03d-1bb99a84419b');
      expect(manifest['app_type'], 'note_action');
      expect(embeddedHtml, startsWith('<!DOCTYPE html>'));
    });

    test('installable YAML is the current HTML', () {
      // plugins/build.sh regenerates the YAML from the HTML; this catches an
      // edit that never got built.
      expect(embeddedHtml, source);
    });

    test('needs no CDN or sidecar at install time', () {
      expect(
        RegExp(r'<script[^>]+\bsrc\s*=', caseSensitive: false)
            .hasMatch(embeddedHtml),
        isFalse,
        reason: 'The installable app must not require a CDN or local sidecar.',
      );
    });

    test('exposes the pure core the offline tests slice out', () {
      // dev/run_core_tests.mjs extracts this region and runs it in Node. If the
      // markers go, that whole suite silently stops testing anything.
      expect(source, contains('/* ==== core:begin =='));
      expect(source, contains('/* ==== core:end =='));
      final begin = source.indexOf('/* ==== core:begin ==');
      final end = source.indexOf('/* ==== core:end ==');
      expect(begin, lessThan(end));
      final core = source.substring(begin, end);
      for (final name in const [
        'function cp437Encode',
        'function toDosBytes',
        'function scanFences',
        'function replaceFence',
        'function setInfoAttr',
        'function dosPathCheck',
        'function parseDosFilesLine',
      ]) {
        expect(core, contains(name), reason: '$name must stay inside the core');
      }
      // The core must stay free of anything Node cannot evaluate.
      for (final forbidden in const ['document.', 'Synapse.', 'state.']) {
        expect(
          core.contains(forbidden),
          isFalse,
          reason: 'the pure core must not reference $forbidden',
        );
      }
    });
  });
}
