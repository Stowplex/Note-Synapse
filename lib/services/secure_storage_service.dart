import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

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
      print('SecureStorageService: Initialized successfully');
    } catch (e) {
      print('SecureStorageService: Initialization failed: $e');
    }
  }

  static const String _apiKeyKey = 'gemini_api_key';

  static Future<void> saveApiKey(String apiKey) async {
    print('SecureStorageService: Saving API key, length: ${apiKey.length}');
    
    try {
      if (Platform.isLinux) {
        // Use shared_preferences as fallback for Linux only
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_apiKeyKey, apiKey);
        print('SecureStorageService: API key saved to SharedPreferences (Linux)');
      } else {
        // Use FlutterSecureStorage for Android/iOS
        await _storage.write(key: _apiKeyKey, value: apiKey);
        print('SecureStorageService: API key saved to FlutterSecureStorage');
      }
      
      // Verify the save worked
      await Future.delayed(const Duration(milliseconds: 100));
      final verifyKey = await getApiKey();
      print('SecureStorageService: Verification - retrieved key length: ${verifyKey?.length ?? 0}');
      
    } catch (e) {
      print('SecureStorageService: Secure storage failed: $e');
      if (Platform.isLinux) {
        // Only fallback to SharedPreferences on Linux
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_apiKeyKey, apiKey);
        print('SecureStorageService: API key saved to SharedPreferences (Linux fallback)');
      } else {
        // On Android/iOS, if secure storage fails, we should not store the key
        print('SecureStorageService: Cannot store API key securely on Android/iOS');
        rethrow;
      }
    }
  }

  static Future<String?> getApiKey() async {
    try {
      print('SecureStorageService: Getting API key...');
      if (Platform.isLinux) {
        // Use shared_preferences as fallback for Linux
        print('SecureStorageService: Using SharedPreferences for Linux');
        final prefs = await SharedPreferences.getInstance();
        final key = prefs.getString(_apiKeyKey);
        print('SecureStorageService: Retrieved key length: ${key?.length ?? 0}');
        return key;
      } else {
        print('SecureStorageService: Using FlutterSecureStorage');
        String? key;
        
        // Try multiple times with small delays
        for (int attempt = 0; attempt < 3; attempt++) {
          try {
            key = await _storage.read(key: _apiKeyKey);
            if (key != null && key.isNotEmpty) break;
            
            if (attempt < 2) {
              print('SecureStorageService: Attempt ${attempt + 1} failed, retrying...');
              await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
            }
          } catch (e) {
            print('SecureStorageService: Attempt ${attempt + 1} error: $e');
            if (attempt < 2) {
              await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
            }
          }
        }
        
        print('SecureStorageService: Retrieved key length: ${key?.length ?? 0}');
        return key;
      }
    } catch (e) {
      print('SecureStorageService: Error in getApiKey: $e');
      if (Platform.isLinux) {
        // Only fallback to SharedPreferences on Linux
        try {
          final prefs = await SharedPreferences.getInstance();
          final key = prefs.getString(_apiKeyKey);
          print('SecureStorageService: Linux fallback key length: ${key?.length ?? 0}');
          return key;
        } catch (fallbackError) {
          print('SecureStorageService: Linux fallback also failed: $fallbackError');
          return null;
        }
      } else {
        // On Android/iOS, if secure storage fails, return null
        print('SecureStorageService: Cannot retrieve API key securely on Android/iOS');
        return null;
      }
    }
  }

  static Future<void> deleteApiKey() async {
    try {
      if (Platform.isLinux) {
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
      print('SecureStorageService: Error in hasApiKey: $e');
      return false;
    }
  }


  // Debug method to check FlutterSecureStorage
  static Future<void> debugStorageContents() async {
    print('=== DEBUGGING STORAGE CONTENTS ===');
    
    // Check FlutterSecureStorage
    try {
      final secureKey = await _storage.read(key: _apiKeyKey);
      print('FlutterSecureStorage key length: ${secureKey?.length ?? 0}');
    } catch (e) {
      print('FlutterSecureStorage error: $e');
    }
    
    print('=== END DEBUGGING ===');
  }

}
