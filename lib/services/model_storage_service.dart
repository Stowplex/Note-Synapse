import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/model_config.dart';
import '../models/model_type.dart';

import 'logger_service.dart';

/// Service for managing model configuration storage
class ModelStorageService {
  static const String _activeModelIdKey = 'active_model_id';
  static const String _configuredModelsKey = 'configured_models';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'note_synapse_secure',
      preferencesKeyPrefix: 'note_synapse_',
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Get the currently active model configuration
  static Future<ModelConfig?> getActiveModel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final activeModelId = prefs.getString(_activeModelIdKey);

      if (activeModelId != null) {
        final models = await getConfiguredModels();
        final activeModel = models.cast<ModelConfig?>().firstWhere(
          (m) => m?.id == activeModelId,
          orElse: () => null,
        );

        if (activeModel != null) {
          LoggerService.debug(
            'ModelStorageService: Active model: ${activeModel.displayName} (${activeModel.id})',
          );
          return activeModel;
        }
      }

      return null;
    } catch (e) {
      LoggerService.error(
        'ModelStorageService: Error getting active model: $e',
      );
      return null;
    }
  }

  /// Set the active model by ID
  static Future<void> activateModel(String modelId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeModelIdKey, modelId);
      LoggerService.debug(
        'ModelStorageService: Set active model ID to: $modelId',
      );
    } catch (e) {
      LoggerService.error(
        'ModelStorageService: Error setting active model: $e',
      );
    }
  }

  /// Get all configured models
  static Future<List<ModelConfig>> getConfiguredModels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configsJson = prefs.getString(_configuredModelsKey);

      if (configsJson == null) return [];

      final configsList = jsonDecode(configsJson) as List<dynamic>;
      final configuredModels = configsList
          .map((json) => ModelConfig.fromJson(json as Map<String, dynamic>))
          .toList();

      LoggerService.debug(
        'ModelStorageService: Found ${configuredModels.length} configured models',
      );
      return configuredModels;
    } catch (e) {
      LoggerService.error(
        'ModelStorageService: Error getting configured models: $e',
      );
      return [];
    }
  }

  /// Add a new model configuration
  static Future<void> addModel(ModelConfig config) async {
    try {
      final models = await getConfiguredModels();
      models.add(config);
      await _saveModels(models);
      LoggerService.debug(
        'ModelStorageService: Added model ${config.displayName} (${config.id})',
      );
    } catch (e) {
      LoggerService.error('ModelStorageService: Error adding model: $e');
    }
  }

  /// Update an existing model configuration
  static Future<void> updateModel(ModelConfig config) async {
    try {
      final models = await getConfiguredModels();
      final index = models.indexWhere((m) => m.id == config.id);

      if (index != -1) {
        models[index] = config;
        await _saveModels(models);
        LoggerService.debug(
          'ModelStorageService: Updated model ${config.displayName} (${config.id})',
        );
      } else {
        LoggerService.error(
          'ModelStorageService: Could not find model to update: ${config.id}',
        );
      }
    } catch (e) {
      LoggerService.error('ModelStorageService: Error updating model: $e');
    }
  }

  /// Delete a model configuration
  static Future<void> deleteModel(String modelId) async {
    try {
      final models = await getConfiguredModels();
      final modelToRemove = models.cast<ModelConfig?>().firstWhere(
        (m) => m?.id == modelId,
        orElse: () => null,
      );

      if (modelToRemove != null) {
        models.removeWhere((m) => m.id == modelId);
        await _saveModels(models);

        // Delete API key
        await deleteModelApiKey(modelId);

        // If this was the active model, clear active model
        final prefs = await SharedPreferences.getInstance();
        final activeId = prefs.getString(_activeModelIdKey);
        if (activeId == modelId) {
          await prefs.remove(_activeModelIdKey);
        }

        LoggerService.debug(
          'ModelStorageService: Deleted model ${modelToRemove.displayName} ($modelId)',
        );
      }
    } catch (e) {
      LoggerService.error('ModelStorageService: Error deleting model: $e');
    }
  }

  /// Save the list of models to SharedPreferences
  static Future<void> _saveModels(List<ModelConfig> models) async {
    final prefs = await SharedPreferences.getInstance();
    final configsJson = jsonEncode(models.map((m) => m.toJson()).toList());
    await prefs.setString(_configuredModelsKey, configsJson);
  }

  /// Save API key securely for a model ID
  static Future<void> saveModelApiKey(String modelId, String apiKey) async {
    try {
      final key = '${modelId}_api_key';
      LoggerService.debug(
        'ModelStorageService: Saving API key for model $modelId, length: ${apiKey.length}',
      );
      await _storage.write(key: key, value: apiKey);
    } catch (e) {
      LoggerService.error('ModelStorageService: Error saving API key: $e');
    }
  }

  /// Get API key for a model ID
  static Future<String?> getModelApiKey(String modelId) async {
    try {
      final key = '${modelId}_api_key';
      final apiKey = await _storage.read(key: key);
      return apiKey;
    } catch (e) {
      LoggerService.error('ModelStorageService: Error getting API key: $e');
      return null;
    }
  }

  /// Delete API key for a model ID
  static Future<void> deleteModelApiKey(String modelId) async {
    try {
      final key = '${modelId}_api_key';
      await _storage.delete(key: key);
    } catch (e) {
      LoggerService.error('ModelStorageService: Error deleting API key: $e');
    }
  }

  /// Clear all model configurations
  static Future<void> clearAllConfigurations() async {
    try {
      final models = await getConfiguredModels();
      for (final model in models) {
        await deleteModelApiKey(model.id);
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeModelIdKey);
      await prefs.remove(_configuredModelsKey);

      LoggerService.debug(
        'ModelStorageService: Cleared all model configurations',
      );
    } catch (e) {
      LoggerService.error(
        'ModelStorageService: Error clearing configurations: $e',
      );
    }
  }

  // Deprecated methods kept for compatibility if needed, or removed.
  // Removing them as we are doing a breaking change.

  /// Get the currently selected model type (Deprecated, maps to active model type)
  static Future<ModelType?> getSelectedModelType() async {
    final activeModel = await getActiveModel();
    return activeModel?.type;
  }
}
