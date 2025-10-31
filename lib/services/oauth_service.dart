import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:crypto/crypto.dart';
import '../models/mcp_endpoint.dart';
import 'logger_service.dart';

class OAuthDiscoveryResult {
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String? registrationEndpoint;
  final List<String>? scopesSupported;

  OAuthDiscoveryResult({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.registrationEndpoint,
    this.scopesSupported,
  });
}

class OAuthService {
  static Future<Map<String, dynamic>> fetchMetadata(String metadataUrl) async {
    final uri = Uri.parse(metadataUrl);
    final response = await http.get(uri);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Metadata request failed (${response.statusCode})');
  }

  static OAuthDiscoveryResult parseMetadata(Map<String, dynamic> json) {
    // Support both OAuth AS discovery and OIDC well-known
    final auth = (json['authorization_endpoint'] ?? json['authorizationEndpoint']) as String?;
    final token = (json['token_endpoint'] ?? json['tokenEndpoint']) as String?;
    final registration = (json['registration_endpoint'] ?? json['registrationEndpoint']) as String?;
    final scopes = (json['scopes_supported'] as List?)?.cast<String>();
    if (auth == null || token == null) {
      throw Exception('Invalid metadata: missing endpoints');
    }
    return OAuthDiscoveryResult(
      authorizationEndpoint: auth,
      tokenEndpoint: token,
      registrationEndpoint: registration,
      scopesSupported: scopes,
    );
  }

  /// Registers a dynamic client (RFC 7591) and returns the client credentials
  static Future<Map<String, String>> registerClient({
    required String registrationEndpoint,
    required String clientName,
    required String redirectUri,
    bool usePkce = true,
  }) async {
    final metadata = {
      'client_name': clientName,
      'redirect_uris': [redirectUri],
      'grant_types': ['authorization_code', 'refresh_token'],
      'response_types': ['code'],
      'token_endpoint_auth_method': usePkce ? 'none' : 'client_secret_basic',
    };

    final response = await http.post(
      Uri.parse(registrationEndpoint),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(metadata),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return {
        'client_id': '${data['client_id']}',
        if (data['client_secret'] != null) 'client_secret': '${data['client_secret']}',
      };
    }
    throw Exception('Client registration failed (${response.statusCode})');
  }

  /// Perform the OAuth Authorization Code flow (with optional PKCE)
  /// Returns token response JSON
  static Future<Map<String, dynamic>> authorizationCodeFlow({
    required OAuthConfig config,
    required String state,
  }) async {
    final verifier = config.usePkce ? _codeVerifier() : null;
    final codeChallenge = config.usePkce && verifier != null ? _codeChallenge(verifier) : null;

    // Use localhost redirect server
    // Use fixed port for compatibility with pre-registered redirect URI
    // If binding fails, surface a clear error instead of falling back,
    // otherwise the redirect URI would mismatch the registered one.
    final int port = 51791;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (e) {
      throw Exception('Unable to bind local redirect server on 127.0.0.1:$port. Ensure the port is free.');
    }
    final redirectUri = 'http://127.0.0.1:$port/callback';

    // Build auth URL
    final authParams = {
      'response_type': 'code',
      'client_id': config.clientId,
      'redirect_uri': redirectUri,
      'scope': config.scope,
      'state': state,
      if (config.usePkce && codeChallenge != null) 'code_challenge': codeChallenge,
      if (config.usePkce && codeChallenge != null) 'code_challenge_method': 'S256',
    };
    final authUri = Uri.parse(config.authorizationEndpoint).replace(queryParameters: authParams);

    LoggerService.debug('OAuthService: Launching auth at: $authUri');
    await launchUrl(authUri, mode: LaunchMode.externalApplication);

    final completer = Completer<Map<String, dynamic>>();
    bool callbackReceived = false;
    
    // Wait for first callback
    server.listen((HttpRequest request) async {
      try {
        if (request.uri.path == '/callback' && !callbackReceived) {
          callbackReceived = true;
          final code = request.uri.queryParameters['code'];
          final returnedState = request.uri.queryParameters['state'];
          
          // Send response immediately
          request.response.statusCode = 200;
          request.response.headers.contentType = ContentType.html;
          request.response.write('<html><body>You can close this window.</body></html>');
          await request.response.close();

          if (code == null || returnedState != state) {
            await server.close(force: true);
            if (!completer.isCompleted) {
              completer.completeError(Exception('Invalid authorization response: missing code or state mismatch'));
            }
            return;
          }

          final tokenBody = {
            'grant_type': 'authorization_code',
            'code': code,
            'client_id': config.clientId,
            'redirect_uri': redirectUri,
          };
          if (!config.usePkce && config.clientSecret != null && config.clientSecret!.isNotEmpty) {
            tokenBody['client_secret'] = config.clientSecret!;
          }
          if (config.usePkce && verifier != null) {
            tokenBody['code_verifier'] = verifier;
          }

          try {
            LoggerService.debug('OAuthService: Exchanging code for token at ${config.tokenEndpoint}');
            final tokenResp = await http.post(
              Uri.parse(config.tokenEndpoint),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: tokenBody,
            );
            // Close server after token exchange completes (success or failure)
            await server.close(force: true);
            
            if (tokenResp.statusCode >= 200 && tokenResp.statusCode < 300) {
              final tokenData = jsonDecode(tokenResp.body) as Map<String, dynamic>;
              if (!completer.isCompleted) {
                completer.complete(tokenData);
              }
            } else {
              if (!completer.isCompleted) {
                completer.completeError(Exception('Token exchange failed (${tokenResp.statusCode}): ${tokenResp.body}'));
              }
            }
          } catch (e) {
            await server.close(force: true);
            LoggerService.error('OAuthService: Token exchange error: $e');
            if (!completer.isCompleted) {
              completer.completeError(Exception('Network error contacting token endpoint: $e'));
            }
          }
        } else {
          // Handle non-callback or duplicate requests
          request.response.statusCode = 404;
          await request.response.close();
        }
      } catch (e) {
        LoggerService.error('OAuthService: authorization flow error: $e');
        try {
          await server.close(force: true);
        } catch (_) {}
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      }
    }).onError((error, stackTrace) {
      LoggerService.error('OAuthService: Server listen error: $error');
      try {
        server.close(force: true);
      } catch (_) {}
      if (!completer.isCompleted) {
        completer.completeError(Exception('OAuth callback server error: $error'));
      }
    });

    try {
      final result = await completer.future.timeout(const Duration(minutes: 5));
      return result;
    } catch (e) {
      // Ensure server is closed on timeout or other errors
      try {
        await server.close(force: true);
      } catch (_) {}
      rethrow;
    }
  }

  static String _codeVerifier() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return _base64UrlNoPad(bytes);
  }

  static String _codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return _base64UrlNoPad(digest.bytes);
  }
}

String _base64UrlNoPad(List<int> bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}


