import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mcp_endpoint.dart';
import 'logger_service.dart';

/// Manages OAuth tokens (access/refresh/id) for a single endpoint.
/// Stores tokens securely and refreshes them as needed.
class OAuthTokenManager {
  static const _tokenPrefix = 'mcp_oauth_token_';
  static const _refreshPrefix = 'mcp_oauth_refresh_';
  static const _idTokenPrefix = 'mcp_oauth_id_';
  static const _expiryPrefix = 'mcp_oauth_expiry_';

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

  final String endpointId;
  final OAuthConfig config;

  OAuthTokenManager({required this.endpointId, required this.config});

  /// Returns a valid access token, refreshing if needed.
  Future<String?> getAccessToken() async {
    try {
      final expiryIso = await _readSecure(_expiryPrefix);
      if (expiryIso != null) {
        final expiry = DateTime.tryParse(expiryIso);
        if (expiry != null && DateTime.now().isAfter(expiry.subtract(const Duration(seconds: 30)))) {
          await _refreshToken();
        }
      }

      return await _readSecure(_tokenPrefix);
    } catch (e) {
      LoggerService.error('OAuthTokenManager: error getting access token: $e');
      return null;
    }
  }

  Future<void> saveTokens(Map<String, dynamic> tokenResponse) async {
    try {
      final accessToken = tokenResponse['access_token'] as String?;
      final refreshToken = tokenResponse['refresh_token'] as String?;
      final idToken = tokenResponse['id_token'] as String?;
      int? expiresIn = tokenResponse['expires_in'] is int
          ? tokenResponse['expires_in'] as int
          : int.tryParse('${tokenResponse['expires_in']}');

      if (accessToken != null) {
        await _writeSecure(_tokenPrefix, accessToken);
      }
      if (refreshToken != null) {
        await _writeSecure(_refreshPrefix, refreshToken);
      }
      if (idToken != null) {
        await _writeSecure(_idTokenPrefix, idToken);
      }
      if (expiresIn != null) {
        final expiry = DateTime.now().add(Duration(seconds: expiresIn));
        await _writeSecure(_expiryPrefix, expiry.toIso8601String());
      }
    } catch (e) {
      LoggerService.error('OAuthTokenManager: error saving tokens: $e');
      rethrow;
    }
  }

  Future<void> _refreshToken() async {
    try {
      final refreshToken = await _readSecure(_refreshPrefix);
      if (refreshToken == null || refreshToken.isEmpty) return;

      final body = {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': config.clientId,
        'redirect_uri': config.redirectUri,
      };
      if (!config.usePkce && config.clientSecret != null && config.clientSecret!.isNotEmpty) {
        body['client_secret'] = config.clientSecret!;
      }

      final response = await http.post(
        Uri.parse(config.tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: body,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        await saveTokens(data);
      } else {
        LoggerService.warning('OAuthTokenManager: refresh failed ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      LoggerService.error('OAuthTokenManager: error refreshing token: $e');
    }
  }

  Future<void> clear() async {
    await _deleteSecure(_tokenPrefix);
    await _deleteSecure(_refreshPrefix);
    await _deleteSecure(_idTokenPrefix);
    await _deleteSecure(_expiryPrefix);
  }

  Future<void> _writeSecure(String prefix, String value) async {
    try {
      await _storage.write(key: '$prefix$endpointId', value: value);
    } catch (_) {
      // Linux fallback
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$prefix$endpointId', value);
    }
  }

  Future<String?> _readSecure(String prefix) async {
    try {
      return await _storage.read(key: '$prefix$endpointId');
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$prefix$endpointId');
    }
  }

  Future<void> _deleteSecure(String prefix) async {
    try {
      await _storage.delete(key: '$prefix$endpointId');
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$prefix$endpointId');
    }
  }
}


