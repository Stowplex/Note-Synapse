import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:note_synapse/widgets/user_app_web_view.dart';

void main() {
  group('resolveSynapseAssetRelativePath', () {
    test('preserves legacy host-only asset URLs', () {
      expect(
        resolveSynapseAssetRelativePath(Uri.parse('synapse://mermaid.min.js')),
        'mermaid.min.js',
      );
    });

    test('supports nested asset paths', () {
      expect(
        resolveSynapseAssetRelativePath(
          Uri.parse('synapse://mathlive/fonts/KaTeX_Main-Regular.woff2'),
        ),
        'mathlive/fonts/KaTeX_Main-Regular.woff2',
      );
    });

    test('rejects traversal and encoded path separators', () {
      expect(
        resolveSynapseAssetRelativePath(
          Uri.parse('synapse://mathlive/%2e%2e/private.js'),
        ),
        isNull,
      );
      expect(
        resolveSynapseAssetRelativePath(
          Uri.parse('synapse://mathlive/fonts%2Fprivate.woff2'),
        ),
        isNull,
      );
      expect(
        resolveSynapseAssetRelativePath(
          Uri.parse('synapse://mathlive/fonts%5Cprivate.woff2'),
        ),
        isNull,
      );
    });

    test('rejects authority forms that are not asset names', () {
      expect(
        resolveSynapseAssetRelativePath(
          Uri.parse('https://mathlive/mathlive.min.js'),
        ),
        isNull,
      );
      expect(
        resolveSynapseAssetRelativePath(
          Uri.parse('synapse://user@mathlive/mathlive.min.js'),
        ),
        isNull,
      );
      expect(
        resolveSynapseAssetRelativePath(
          Uri.parse('synapse://mathlive:42/mathlive.min.js'),
        ),
        isNull,
      );
    });
  });

  group('synapseAssetContentType', () {
    test('returns executable and font MIME types', () {
      expect(
        synapseAssetContentType('mathlive/mathlive.min.js'),
        'application/javascript',
      );
      expect(synapseAssetContentType('styles/editor.css'), 'text/css');
      expect(
        synapseAssetContentType('mathlive/fonts/math.woff2'),
        'font/woff2',
      );
    });

    test('uses a safe binary fallback', () {
      expect(
        synapseAssetContentType('library/data.bin'),
        'application/octet-stream',
      );
    });
  });

  test('vendored nested JavaScript and font assets are packaged', () async {
    final engine = await rootBundle.load(
      'assets/scripts/compute-engine/compute-engine.min.js',
    );
    final font = await rootBundle.load(
      'assets/scripts/mathlive/fonts/KaTeX_Main-Regular.woff2',
    );

    expect(engine.lengthInBytes, greaterThan(1000000));
    expect(font.lengthInBytes, greaterThan(1000));
  });
}
