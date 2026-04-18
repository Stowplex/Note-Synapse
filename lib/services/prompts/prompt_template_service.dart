import 'package:flutter/services.dart';
import 'package:mustache_template/mustache_template.dart';

import '../../utils/prompt_injection_protection.dart';

/// Loads Mustache templates from Flutter assets, caches them, and renders
/// with a provided context map.
///
/// Call [preloadAll] once at startup so that all subsequent [renderSync]
/// calls can be synchronous.
class PromptTemplateService {
  final Map<String, Template> _cache = {};

  /// Pre-load and compile every template under assets/prompts/.
  /// Must be called after [WidgetsFlutterBinding.ensureInitialized].
  Future<void> preloadAll() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final promptPaths = manifest
        .listAssets()
        .where((key) => key.startsWith('assets/prompts/') && key.endsWith('.md'));
    for (final fullPath in promptPaths) {
      final templatePath = fullPath
          .replaceFirst('assets/prompts/', '')
          .replaceFirst('.md', '');
      await _loadTemplate(templatePath);
    }
  }

  /// Render a pre-loaded template synchronously.
  ///
  /// [templatePath] is relative to assets/prompts/, without .md extension.
  /// e.g., 'guidelines/math_formula'
  ///
  /// Throws [StateError] if the template was not pre-loaded.
  String renderSync(String templatePath, [Map<String, dynamic>? context]) {
    final template = _cache[templatePath];
    if (template == null) {
      throw StateError(
        'Template "$templatePath" not pre-loaded. '
        'Call preloadAll() at startup.',
      );
    }
    return template.renderString(context ?? {});
  }

  /// Async render -- loads from assets on demand if not cached.
  Future<String> render(String templatePath, [Map<String, dynamic>? context]) async {
    if (!_cache.containsKey(templatePath)) {
      await _loadTemplate(templatePath);
    }
    return _cache[templatePath]!.renderString(context ?? {});
  }

  /// Build a context map with the standard security lambdas pre-registered.
  static Map<String, dynamic> securityContext() {
    return {
      'safeWrap': (LambdaContext ctx) =>
          PromptInjectionProtection.formatNoteContentAsData(ctx.renderString()),
      'safeTitle': (LambdaContext ctx) =>
          PromptInjectionProtection.formatTitleAsData(ctx.renderString()),
    };
  }

  Future<void> _loadTemplate(String path) async {
    if (_cache.containsKey(path)) return;
    final content = await rootBundle.loadString('assets/prompts/$path.md');
    _cache[path] = Template(content, name: path);
  }

  /// Visible for testing: number of cached templates.
  int get cacheSize => _cache.length;
}
