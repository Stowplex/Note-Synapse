import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/model_config.dart';
import '../models/model_type.dart';
import 'logger_service.dart';

/// Service for managing model configuration storage
class ModelStorageService {
  static const String _selectedModelKey = 'selected_model';
  static const String _modelConfigsKey = 'model_configs';
  
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

  /// Get the currently selected model type
  static Future<ModelType> getSelectedModel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modelId = prefs.getString(_selectedModelKey);
      
      if (modelId != null) {
        final modelType = ModelType.fromId(modelId);
        if (modelType != null) {
          LoggerService.debug('ModelStorageService: Selected model: ${modelType.displayName}');
          return modelType;
        }
      }
      
      // Default to Gemini 2.5 Flash
      LoggerService.debug('ModelStorageService: Using default model: Gemini 2.5 Flash');
      return ModelType.gemini25Flash;
    } catch (e) {
      LoggerService.error('ModelStorageService: Error getting selected model: $e');
      return ModelType.gemini25Flash;
    }
  }

  /// Set the currently selected model type
  static Future<void> setSelectedModel(ModelType modelType) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedModelKey, modelType.id);
      LoggerService.debug('ModelStorageService: Set selected model to: ${modelType.displayName}');
    } catch (e) {
      LoggerService.error('ModelStorageService: Error setting selected model: $e');
    }
  }

  /// Get configuration for a specific model
  static Future<ModelConfig> getModelConfig(ModelType modelType) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configsJson = prefs.getString(_modelConfigsKey);
      
      if (configsJson != null) {
        final configsMap = jsonDecode(configsJson) as Map<String, dynamic>;
        final modelConfigs = configsMap.map(
          (key, value) => MapEntry(key, ModelConfig.fromJson(value as Map<String, dynamic>))
        );
        
        final config = modelConfigs[modelType.id];
        if (config != null) {
          LoggerService.debug('ModelStorageService: Found config for ${modelType.displayName}');
          return config;
        }
      }
      
      // Return default config
      LoggerService.debug('ModelStorageService: Using default config for ${modelType.displayName}');
      return ModelConfig(type: modelType);
    } catch (e) {
      LoggerService.error('ModelStorageService: Error getting model config: $e');
      return ModelConfig(type: modelType);
    }
  }

  /// Save configuration for a specific model
  static Future<void> saveModelConfig(ModelConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configsJson = prefs.getString(_modelConfigsKey);
      
      Map<String, dynamic> configsMap = {};
      if (configsJson != null) {
        configsMap = jsonDecode(configsJson) as Map<String, dynamic>;
      }
      
      configsMap[config.type.id] = config.toJson();
      await prefs.setString(_modelConfigsKey, jsonEncode(configsMap));
      
      LoggerService.debug('ModelStorageService: Saved config for ${config.type.displayName}');
    } catch (e) {
      LoggerService.error('ModelStorageService: Error saving model config: $e');
    }
  }

  /// Save API key securely for a model
  static Future<void> saveModelApiKey(ModelType modelType, String apiKey) async {
    try {
      final key = '${modelType.id}_api_key';
      LoggerService.debug('ModelStorageService: Saving API key for ${modelType.displayName}, length: ${apiKey.length}, key: $key');
      await _storage.write(key: key, value: apiKey);
      LoggerService.debug('ModelStorageService: Successfully saved API key for ${modelType.displayName}');
    } catch (e) {
      LoggerService.error('ModelStorageService: Error saving API key: $e');
    }
  }

  /// Get API key for a model
  static Future<String?> getModelApiKey(ModelType modelType) async {
    try {
      final key = '${modelType.id}_api_key';
      LoggerService.debug('ModelStorageService: Reading API key for ${modelType.displayName}, key: $key');
      final apiKey = await _storage.read(key: key);
      LoggerService.debug('ModelStorageService: Retrieved API key for ${modelType.displayName}: ${apiKey != null ? 'present (length: ${apiKey.length})' : 'not found'}');
      return apiKey;
    } catch (e) {
      LoggerService.error('ModelStorageService: Error getting API key: $e');
      return null;
    }
  }

  /// Delete API key for a model
  static Future<void> deleteModelApiKey(ModelType modelType) async {
    try {
      final key = '${modelType.id}_api_key';
      await _storage.delete(key: key);
      LoggerService.debug('ModelStorageService: Deleted API key for ${modelType.displayName}');
    } catch (e) {
      LoggerService.error('ModelStorageService: Error deleting API key: $e');
    }
  }

  /// Check if a model is configured
  static Future<bool> isModelConfigured(ModelType modelType) async {
    try {
      final config = await getModelConfig(modelType);
      return config.isConfigured;
    } catch (e) {
      LoggerService.error('ModelStorageService: Error checking if model is configured: $e');
      return false;
    }
  }

  /// Get all configured models
  static Future<List<ModelType>> getConfiguredModels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configsJson = prefs.getString(_modelConfigsKey);
      
      if (configsJson == null) return [];
      
      final configsMap = jsonDecode(configsJson) as Map<String, dynamic>;
      final configuredModels = <ModelType>[];
      
      for (final entry in configsMap.entries) {
        final config = ModelConfig.fromJson(entry.value as Map<String, dynamic>);
        if (config.isConfigured) {
          final modelType = ModelType.fromId(entry.key);
          if (modelType != null) {
            configuredModels.add(modelType);
          }
        }
      }
      
      LoggerService.debug('ModelStorageService: Found ${configuredModels.length} configured models');
      return configuredModels;
    } catch (e) {
      LoggerService.error('ModelStorageService: Error getting configured models: $e');
      return [];
    }
  }

  /// Reset configuration for a specific model (mark as not configured)
  static Future<void> resetModelConfiguration(ModelType modelType) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configsJson = prefs.getString(_modelConfigsKey);
      
      if (configsJson != null) {
        final configsMap = jsonDecode(configsJson) as Map<String, dynamic>;
        final modelConfigs = configsMap.map(
          (key, value) => MapEntry(key, ModelConfig.fromJson(value as Map<String, dynamic>))
        );
        
        // Reset the specific model configuration
        modelConfigs[modelType.id] = ModelConfig(type: modelType);
        
        // Save back to preferences
        final updatedConfigsMap = modelConfigs.map(
          (key, value) => MapEntry(key, value.toJson())
        );
        await prefs.setString(_modelConfigsKey, jsonEncode(updatedConfigsMap));
        
        LoggerService.debug('ModelStorageService: Reset configuration for ${modelType.displayName}');
      }
    } catch (e) {
      LoggerService.error('ModelStorageService: Error resetting model configuration: $e');
    }
  }

  /// Clear all model configurations
  static Future<void> clearAllConfigurations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_selectedModelKey);
      await prefs.remove(_modelConfigsKey);
      
      // Clear all API keys
      for (final modelType in ModelType.all) {
        await deleteModelApiKey(modelType);
      }
      
      LoggerService.debug('ModelStorageService: Cleared all model configurations');
    } catch (e) {
      LoggerService.error('ModelStorageService: Error clearing configurations: $e');
    }
  }
}
