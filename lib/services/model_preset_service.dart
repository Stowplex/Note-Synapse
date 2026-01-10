import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';
import '../models/model_config.dart';
import '../models/model_type.dart';
import '../models/model_capabilities.dart';
import 'logger_service.dart';

/// Service for loading model presets from assets
class ModelPresetService {
  static final ModelPresetService _instance = ModelPresetService._internal();
  static ModelPresetService get instance => _instance;

  ModelPresetService._internal();

  List<ModelConfig>? _cachedPresets;
  final Map<String, String> _presetApiKeyUrls = {};
  final Map<String, bool> _premiumWarnings = {};

  /// Load all available model presets
  Future<List<ModelConfig>> loadPresets({bool forceRefresh = false}) async {
    if (_cachedPresets != null && !forceRefresh) {
      return _cachedPresets!;
    }

    try {
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);

      final presetFiles = manifestMap.keys
          .where((String key) => key.startsWith('assets/model_presets/'))
          .toList();

      List<ModelConfig> presets = [];
      _presetApiKeyUrls.clear();
      _premiumWarnings.clear();

      for (final file in presetFiles) {
        try {
          final yamlString = await rootBundle.loadString(file);
          final doc = loadYaml(yamlString);

          final modelTypeString = doc['model_type'] as String?;
          if (modelTypeString == null) continue;

          final modelType = ModelType.fromId(modelTypeString);
          if (modelType == null) continue;

          final displayName = doc['model_display_name'] as String?;
          if (displayName != null) {
            _premiumWarnings[displayName] =
                doc['warn_premium'] as bool? ?? false;

            // Store API key URL for this preset
            final apiKeyUrl = doc['api_key_url'] as String?;
            if (apiKeyUrl != null) {
              _presetApiKeyUrls[displayName] = apiKeyUrl;
            }
          }

          final capabilities = ModelCapabilities(
            maxInputTokens: doc['max_input_token'] ?? 100000,
            maxOutputTokens: doc['max_output_token'] ?? 4000,
            supportsImages:
                doc['model_capabilities']?.contains('support_image') ?? false,
            supportsDocuments:
                doc['model_capabilities']?.contains(
                  'support_document_understanding',
                ) ??
                false,
            supportsAudio:
                doc['model_capabilities']?.contains('support_audio') ?? false,
            supportsVideo:
                doc['model_capabilities']?.contains('support_video') ?? false,
            supportsImageGeneration:
                doc['model_capabilities']?.contains('generate_image') ?? false,
            supportsCodeGeneration:
                doc['model_capabilities']?.contains('support_code_generation') ?? false,
          );

          final supportedAttachmentMimeTypes =
              (doc['supported_attachment_mime_types'] as YamlList?)
                  ?.cast<dynamic>()
                  .whereType<String>()
                  .map((value) => value.trim())
                  .toList();

          final modelFeatures = (doc['model_features'] as YamlList?)
              ?.cast<dynamic>()
              .whereType<String>()
              .map((value) => value.trim())
              .toList();

          final preset = ModelConfig(
            type: modelType,
            endpoint: doc['model_endpoint'],
            modelName: doc['model_name'],
            displayName: displayName,
            maxInputTokens: doc['max_input_token'],
            maxOutputTokens: doc['max_output_token'],
            customCapabilitiesObject: capabilities,
            supportedAttachmentMimeTypes: supportedAttachmentMimeTypes,
            modelFeatures: modelFeatures,
          );

          presets.add(preset);
        } catch (e) {
          LoggerService.error('Error loading preset from $file: $e');
        }
      }

      _cachedPresets = presets;
      return presets;
    } catch (e) {
      LoggerService.error('Error loading presets: $e');
      return [];
    }
  }

  /// Get a specific preset by model type
  /// Note: This finds the first preset matching the type.
  /// If multiple presets exist for a type, this might need refinement.
  Future<ModelConfig?> getPresetForType(ModelType type) async {
    final presets = await loadPresets();
    try {
      return presets.firstWhere((p) => p.type == type);
    } catch (_) {
      return null;
    }
  }

  /// Get API key URL for a specific model display name
  String? getApiKeyUrl(String displayName) {
    return _presetApiKeyUrls[displayName];
  }

  /// Check if a model has a premium warning
  bool hasPremiumWarning(String displayName) {
    return _premiumWarnings[displayName] ?? false;
  }
}
