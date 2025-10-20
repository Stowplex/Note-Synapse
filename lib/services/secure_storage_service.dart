import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'logger_service.dart';

class SecureStorageService {
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

  // Initialize secure storage
  static Future<void> initialize() async {
    try {
      // Test if storage is accessible by trying to read a non-existent key
      await _storage.read(key: 'test_key');
      LoggerService.debug('SecureStorageService: Initialized successfully');
    } catch (e) {
      LoggerService.error('SecureStorageService: Initialization failed: $e', error: e);
    }
  }

  static const String _apiKeyKey = 'gemini_api_key';

  /// Check if running on Linux (non-web)
  static bool get _isLinux => !kIsWeb && Platform.isLinux;

  static Future<void> saveApiKey(String apiKey) async {
    LoggerService.debug('SecureStorageService: Saving API key, length: ${apiKey.length}');
    
    try {
      if (_isLinux) {
        // Use shared_preferences as fallback for Linux only
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_apiKeyKey, apiKey);
        LoggerService.debug('SecureStorageService: API key saved to SharedPreferences (Linux)');
      } else {
        // Use FlutterSecureStorage for Android/iOS
        await _storage.write(key: _apiKeyKey, value: apiKey);
        LoggerService.debug('SecureStorageService: API key saved to FlutterSecureStorage');
      }
      
      // Verify the save worked
      await Future.delayed(const Duration(milliseconds: 100));
      final verifyKey = await getApiKey();
      LoggerService.debug('SecureStorageService: Verification - retrieved key length: ${verifyKey?.length ?? 0}');
      
    } catch (e) {
      LoggerService.error('SecureStorageService: Secure storage failed: $e', error: e);
      if (_isLinux) {
        // Only fallback to SharedPreferences on Linux
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_apiKeyKey, apiKey);
        LoggerService.debug('SecureStorageService: API key saved to SharedPreferences (Linux fallback)');
      } else {
        // On Android/iOS, if secure storage fails, we should not store the key
        LoggerService.warning('SecureStorageService: Cannot store API key securely on Android/iOS');
        rethrow;
      }
    }
  }

  static Future<String?> getApiKey() async {
    try {
      LoggerService.debug('SecureStorageService: Getting API key...');
      if (_isLinux) {
        // Use shared_preferences as fallback for Linux
        LoggerService.debug('SecureStorageService: Using SharedPreferences for Linux');
        final prefs = await SharedPreferences.getInstance();
        final key = prefs.getString(_apiKeyKey);
        LoggerService.debug('SecureStorageService: Retrieved key length: ${key?.length ?? 0}');
        return key;
      } else {
        LoggerService.debug('SecureStorageService: Using FlutterSecureStorage');
        String? key;
        
        // Try multiple times with small delays
        for (int attempt = 0; attempt < 3; attempt++) {
          try {
            key = await _storage.read(key: _apiKeyKey);
            if (key != null && key.isNotEmpty) break;
            
            if (attempt < 2) {
              LoggerService.debug('SecureStorageService: Attempt ${attempt + 1} failed, retrying...');
              await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
            }
          } catch (e) {
            LoggerService.debug('SecureStorageService: Attempt ${attempt + 1} error: $e');
            if (attempt < 2) {
              await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
            }
          }
        }
        
        LoggerService.debug('SecureStorageService: Retrieved key length: ${key?.length ?? 0}');
        return key;
      }
    } catch (e) {
      LoggerService.error('SecureStorageService: Error in getApiKey: $e', error: e);
      if (_isLinux) {
        // Only fallback to SharedPreferences on Linux
        try {
          final prefs = await SharedPreferences.getInstance();
          final key = prefs.getString(_apiKeyKey);
          LoggerService.debug('SecureStorageService: Linux fallback key length: ${key?.length ?? 0}');
          return key;
        } catch (fallbackError) {
          LoggerService.error('SecureStorageService: Linux fallback also failed: $fallbackError', error: fallbackError);
          return null;
        }
      } else {
        // On Android/iOS, if secure storage fails, return null
        LoggerService.warning('SecureStorageService: Cannot retrieve API key securely on Android/iOS');
        return null;
      }
    }
  }

  static Future<void> deleteApiKey() async {
    try {
      if (_isLinux) {
        // Use shared_preferences as fallback for Linux
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_apiKeyKey);
      } else {
        await _storage.delete(key: _apiKeyKey);
      }
    } catch (e) {
      // Fallback to shared_preferences if secure storage fails
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_apiKeyKey);
    }
  }

  static Future<bool> hasApiKey() async {
    try {
      final key = await getApiKey();
      return key != null && key.isNotEmpty;
    } catch (e) {
      LoggerService.error('SecureStorageService: Error in hasApiKey: $e', error: e);
      return false;
    }
  }


  // Debug method to check FlutterSecureStorage
  static Future<void> debugStorageContents() async {
    LoggerService.debug('=== DEBUGGING STORAGE CONTENTS ===');
    
    // Check FlutterSecureStorage
    try {
      final secureKey = await _storage.read(key: _apiKeyKey);
      LoggerService.debug('FlutterSecureStorage key length: ${secureKey?.length ?? 0}');
    } catch (e) {
      LoggerService.error('FlutterSecureStorage error: $e', error: e);
    }
    
    LoggerService.debug('=== END DEBUGGING ===');
  }

}
