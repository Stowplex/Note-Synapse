import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/prompts/prompt_template_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PromptTemplateService service;

  setUp(() {
    service = PromptTemplateService();
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

    test('renderSync works after render caches the template', () async {
      // In the test environment AssetManifest.json is not available,
      // so we exercise the on-demand render path which populates the
      // cache, then verify renderSync returns the same content.
      await service.render('guidelines/math_formula');
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
