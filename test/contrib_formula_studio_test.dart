import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const contribYaml = 'contrib/formula-studio/plugins/Formula_Studio.yaml';
  const starterYaml = 'assets/starter/apps/Formula_Studio.yaml';
  const sourceHtml = 'contrib/formula-studio/plugins/formula_studio.html';

  late String embeddedHtml;

  setUpAll(() {
    final yaml = loadYaml(File(contribYaml).readAsStringSync()) as YamlMap;
    embeddedHtml = utf8.decode(base64Decode(yaml['code'] as String));
  });

  test('metadata identifies a stable offline Note Action', () {
    final yaml = loadYaml(File(contribYaml).readAsStringSync()) as YamlMap;
    expect(yaml['name'], 'Formula Studio');
    expect(yaml['uuid'], '7cbb556a-900b-4a74-b9bd-e95897c3480d');
    expect(yaml['app_type'], 'note_action');
    expect(yaml['description'], contains('Fully offline'));
  });

  test('starter copy is byte-identical to the contrib build', () {
    expect(
      File(starterYaml).readAsBytesSync(),
      File(contribYaml).readAsBytesSync(),
    );
  });

  test('embedded app exactly matches readable sources after inlining', () {
    var expected = File(sourceHtml).readAsStringSync();
    final scriptPattern = RegExp(r'(\s*)<script src="(src/[^"]+)"></script>');
    expected = expected.replaceAllMapped(scriptPattern, (match) {
      final indent = match.group(1)!;
      final path = 'contrib/formula-studio/plugins/${match.group(2)}';
      final source = File(
        path,
      ).readAsStringSync().replaceAll('</script>', r'<\/script>');
      return '$indent<script>\n$source\n  </script>';
    });
    expect(embeddedHtml, expected);
  });

  test('only bundled synapse dependencies remain as script sources', () {
    final sources = RegExp(
      r'<script[^>]*src="([^"]+)"',
    ).allMatches(embeddedHtml).map((match) => match.group(1)).toList();
    expect(sources, [
      'synapse://mathlive/mathlive.min.js',
      'synapse://compute-engine/compute-engine.min.js',
    ]);
  });

  test('offline policy and local MathLive configuration are present', () {
    expect(embeddedHtml, contains("connect-src 'none'"));
    expect(
      embeddedHtml,
      contains(
        'MathfieldElement.fontsDirectory = "synapse://mathlive/fonts/";',
      ),
    );
    expect(embeddedHtml, contains('MathfieldElement.soundsDirectory = null;'));
    expect(
      embeddedHtml,
      isNot(matches(RegExp(r'<(?:script|link)[^>]*(?:src|href)="https?://'))),
    );
  });

  test('first-party app code exposes no network primitive', () {
    final sourceFiles = Directory(
      'contrib/formula-studio/plugins/src',
    ).listSync().whereType<File>().where((file) => file.path.endsWith('.js'));
    final forbidden = RegExp(
      r'(^|[^A-Za-z])(fetch|XMLHttpRequest|WebSocket|proxyFetch|originFetch)([^A-Za-z]|$)',
      multiLine: true,
    );
    for (final file in sourceFiles) {
      expect(
        file.readAsStringSync(),
        isNot(matches(forbidden)),
        reason: file.path,
      );
    }
  });

  test('app includes every approved evaluator action except plotting', () {
    for (final action in [
      'simplify',
      'exact',
      'decimal',
      'substitute',
      'expand',
      'factor',
      'solve',
      'derivative',
      'integral',
      'definiteIntegral',
      'numericIntegral',
      'limit',
    ]) {
      expect(embeddedHtml, contains('data-action="$action"'));
    }
    expect(embeddedHtml, isNot(contains('data-action="plot"')));
  });

  test('visual editor includes a fraction template button', () {
    expect(embeddedHtml, contains('id="fractionButton"'));
    expect(embeddedHtml, contains(r'data-template="\frac{#0}{#?}"'));
    expect(embeddedHtml, contains('insertVisualTemplate'));
    expect(embeddedHtml, contains("insertFraction: 'Insert fraction'"));
    expect(embeddedHtml, contains("insertFraction: '插入分数'"));
  });

  test('English and Simplified Chinese strings ship in the app', () {
    expect(embeddedHtml, contains('Formula Studio'));
    expect(embeddedHtml, contains('公式工作室'));
    expect(embeddedHtml, contains('calculationUnavailable'));
  });
}
