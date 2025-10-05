import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static const String _apiKeyKey = 'gemini_api_key';

  static Future<void> saveApiKey(String apiKey) async {
    try {
      if (Platform.isLinux) {
        // Use shared_preferences as fallback for Linux
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_apiKeyKey, apiKey);
      } else {
        await _storage.write(key: _apiKeyKey, value: apiKey);
      }
    } catch (e) {
      // Fallback to shared_preferences if secure storage fails
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_apiKeyKey, apiKey);
    }
  }

  static Future<String?> getApiKey() async {
    try {
      if (Platform.isLinux) {
        // Use shared_preferences as fallback for Linux
        final prefs = await SharedPreferences.getInstance();
        return prefs.getString(_apiKeyKey);
      } else {
        return await _storage.read(key: _apiKeyKey);
      }
    } catch (e) {
      // Fallback to shared_preferences if secure storage fails
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_apiKeyKey);
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
    final key = await getApiKey();
    return key != null && key.isNotEmpty;
  }
}
