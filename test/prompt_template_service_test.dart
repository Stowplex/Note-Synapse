import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/prompts/prompt_template_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PromptTemplateService service;

  setUp(() {
    service = PromptTemplateService();

    // Mock the Flutter asset channel so we can exercise preloadAll without
    // relying on AssetManifest.json being built for the test binary. The
    // AssetManifest lookup returns a hand-crafted manifest listing our test
    // asset; actual .md requests are resolved by reading the real file
    // from disk (tests run with cwd at the package root).
    final manifest = <String, List<Object>>{
      'assets/prompts/guidelines/math_formula.md': [
        {'asset': 'assets/prompts/guidelines/math_formula.md'},
      ],
    };
    final manifestBytes =
        const StandardMessageCodec().encodeMessage(manifest)!;

    TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (ByteData? message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      if (key == 'AssetManifest.bin') {
        return manifestBytes;
      }
      if (key.startsWith('assets/prompts/') && key.endsWith('.md')) {
        final file = File(key);
        if (file.existsSync()) {
          final bytes = Uint8List.fromList(file.readAsBytesSync());
          return ByteData.view(bytes.buffer);
        }
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  group('PromptTemplateService', () {
    test('render loads and renders a template with no variables', () async {
      final result = await service.render('guidelines/math_formula');
      expect(result, contains('Math Output Contract:'));
      expect(result, contains(r'\( E = mc^2 \)'));
    });

    test('renderSync throws if template not pre-loaded', () {
      expect(
        () => service.renderSync('nonexistent/template'),
        throwsA(isA<StateError>()),
      );
    });

    test('renderSync works after preloadAll', () async {
      await service.preloadAll();
      expect(service.cacheSize, greaterThan(0));
      final result = service.renderSync('guidelines/math_formula');
      expect(result, contains('Math Output Contract:'));
    });

    test('securityContext provides safeWrap and safeTitle lambdas', () {
      final ctx = PromptTemplateService.securityContext();
      expect(ctx, contains('safeWrap'));
      expect(ctx, contains('safeTitle'));
    });
  });
}
