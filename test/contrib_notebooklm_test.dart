import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const pluginRoot = 'contrib/notebooklm/plugins';
  const yamlPath = '$pluginRoot/NotebookLM_Manager.yaml';
  const sourcePath = '$pluginRoot/notebooklm_manager.html';

  group('NotebookLM Manager contrib app', () {
    late String source;
    late String embeddedHtml;
    late YamlMap manifest;

    setUpAll(() {
      source = File(sourcePath).readAsStringSync();
      manifest = loadYaml(File(yamlPath).readAsStringSync()) as YamlMap;
      embeddedHtml = utf8.decode(base64Decode(manifest['code'] as String));
    });

    test('has installable ai-tool metadata', () {
      expect(manifest['name'], 'NotebookLM Manager');
      expect(manifest['uuid'], 'a80d7d5b-0ce5-48bd-8641-9eb357a7e020');
      expect(manifest['app_type'], 'ai_tool');
      expect(embeddedHtml, startsWith('<!DOCTYPE html>'));
    });

    test('installable YAML is the current HTML', () {
      // plugins/build.sh regenerates the YAML from the HTML; this catches an
      // edit that never got built.
      expect(embeddedHtml, source);
    });

    test('needs no CDN or sidecar at install time', () {
      expect(
        RegExp(
          r'<script[^>]+\bsrc\s*=',
          caseSensitive: false,
        ).hasMatch(embeddedHtml),
        isFalse,
        reason: 'The installable app must not require a CDN or local sidecar.',
      );
    });

    test('resolves the NotebookLM origin at runtime', () {
      // Google moved the app from notebooklm.google.com to notebook.google.com
      // ("Gemini Notebook"); the old host 301s there. The plugin must follow
      // whatever allowlisted host the page lands on rather than pinning one.
      expect(source, contains("DEFAULT_ORIGIN: 'https://notebook.google.com'"));
      expect(
        source,
        contains("HOSTS: ['notebook.google.com', 'notebooklm.google.com']"),
      );
      expect(source, contains('let nlmOrigin = NLM.DEFAULT_ORIGIN'));
      // The only literal hosts are the allowlist entries above.
      final literalHosts = RegExp(
        r"'https://notebook(?:lm)?\.google\.com'",
      ).allMatches(source).length;
      expect(literalHosts, 1, reason: 'route every request through nlmOrigin');
      expect(source.contains('NLM.ORIGIN'), isFalse);
    });

    test('understands the slot-5 gRPC error rows', () {
      // Failures arrive as HTTP 200 with
      // ["wrb.fr", rpc, null, null, null, [code], "generic"]; a parser that
      // only knows the ["er", …] envelope renders a dead session as an empty
      // notebook list. dev/run.js drives these paths against captured rows.
      expect(source, contains('function rpcStatus('));
      expect(source, contains('function errorCodeFromEnvelope('));
      expect(source, contains("status.code === 16"));
      expect(source, contains("status.code === 8"));
      expect(source, contains("'nlm_error_drift'"));
      expect(source, contains("'nlm_error_empty'"));
    });
  });
}
