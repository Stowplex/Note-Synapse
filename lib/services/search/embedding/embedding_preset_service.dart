import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';

import '../../logger_service.dart';
import 'embedding_provider.dart';

/// Service for loading embedding provider presets from
/// `assets/embedding_presets/` (mirrors [ModelPresetService]'s asset-manifest
/// scan + per-file YAML parse).
///
/// Preset fields: model_type (gemini|openai|local), model_endpoint,
/// model_name, model_display_name, api_key_url, dimensions, supports_images,
/// plus supports_batch (gemini), send_dimensions (openai), and
/// model_url/tokenizer_url (local — flutter_gemma's two-file embedder
/// install; both are required for a local preset to load).
class EmbeddingPresetService {
  static final EmbeddingPresetService _instance =
      EmbeddingPresetService._internal();
  static EmbeddingPresetService get instance => _instance;

  EmbeddingPresetService._internal() : _listAssets = null, _loadAsset = null;

  /// Test-only constructor with injectable asset listing/loading (mirrors
  /// the HTTP/embed seams of the providers: rootBundle carries real bundled
  /// assets in `flutter test`, so malformed-preset cases need fixtures).
  @visibleForTesting
  EmbeddingPresetService.forTesting({
    required Future<List<String>> Function() listAssets,
    required Future<String> Function(String key) loadAsset,
  }) : _listAssets = listAssets,
       _loadAsset = loadAsset;

  static const Set<String> _supportedTypes = {'gemini', 'openai', 'local'};

  final Future<List<String>> Function()? _listAssets;
  final Future<String> Function(String key)? _loadAsset;

  List<EmbeddingProviderConfig>? _cachedPresets;

  Future<List<String>> _listPresetAssets() async {
    final lister = _listAssets;
    if (lister != null) return lister();
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return manifest.listAssets();
  }

  Future<String> _loadPresetAsset(String key) {
    final loader = _loadAsset;
    if (loader != null) return loader(key);
    return rootBundle.loadString(key);
  }

  /// Load all available embedding presets.
  Future<List<EmbeddingProviderConfig>> loadPresets({
    bool forceRefresh = false,
  }) async {
    if (_cachedPresets != null && !forceRefresh) {
      return _cachedPresets!;
    }

    try {
      final presetFiles = (await _listPresetAssets())
          .where((key) => key.startsWith('assets/embedding_presets/'))
          .toList();

      final presets = <EmbeddingProviderConfig>[];

      for (final file in presetFiles) {
        try {
          final yamlString = await _loadPresetAsset(file);
          final doc = loadYaml(yamlString);

          final type = doc['model_type'] as String?;
          if (type == null || !_supportedTypes.contains(type)) continue;

          final modelName = doc['model_name'] as String?;
          if (modelName == null || modelName.isEmpty) continue;

          final modelUrl = doc['model_url'] as String?;
          final tokenizerUrl = doc['tokenizer_url'] as String?;
          if (type == 'local' &&
              (modelUrl == null ||
                  modelUrl.isEmpty ||
                  tokenizerUrl == null ||
                  tokenizerUrl.isEmpty)) {
            // A local preset without both download URLs can never install.
            LoggerService.error(
              'Skipping local embedding preset $file: '
              'model_url and tokenizer_url are both required',
            );
            continue;
          }

          presets.add(
            EmbeddingProviderConfig(
              type: type,
              endpoint: doc['model_endpoint'] as String?,
              modelName: modelName,
              displayName: doc['model_display_name'] as String? ?? modelName,
              dimensions: doc['dimensions'] as int? ?? 768,
              supportsImages: doc['supports_images'] as bool? ?? false,
              supportsBatch: doc['supports_batch'] as bool? ?? true,
              sendDimensions: doc['send_dimensions'] as bool? ?? false,
              modelUrl: modelUrl,
              tokenizerUrl: tokenizerUrl,
              apiKeyUrl: doc['api_key_url'] as String?,
            ),
          );
        } catch (e) {
          LoggerService.error('Error loading embedding preset from $file: $e');
        }
      }

      _cachedPresets = presets;
      return presets;
    } catch (e) {
      LoggerService.error('Error loading embedding presets: $e');
      return [];
    }
  }

  /// Find a preset by its stable identity (type + model name).
  Future<EmbeddingProviderConfig?> getPreset(
    String type,
    String modelName,
  ) async {
    final presets = await loadPresets();
    for (final preset in presets) {
      if (preset.type == type && preset.modelName == modelName) {
        return preset;
      }
    }
    return null;
  }
}
