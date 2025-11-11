import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:crypto/crypto.dart';
import '../models/mcp_endpoint.dart';
import 'logger_service.dart';
import 'oauth_redirect_helper.dart';

class ResourceDiscoveryResult {
  ResourceDiscoveryResult({
    required this.metadataUrl,
    required this.metadata,
    required this.authorizationServers,
    required this.scopeHint,
    required this.isAuthorizationMetadata,
    this.authorizationMetadata,
    this.authorizationMetadataUrl,
    this.issuer,
  });

  final String? metadataUrl;
  final Map<String, dynamic>? metadata;
  final List<String> authorizationServers;
  final String? scopeHint;
  final bool isAuthorizationMetadata;
  final Map<String, dynamic>? authorizationMetadata;
  final String? authorizationMetadataUrl;
  final String? issuer;
}

class AuthorizationServerMetadataResult {
  AuthorizationServerMetadataResult({
    required this.issuer,
    required this.metadataUrl,
    required this.metadata,
  });

  final String issuer;
  final String metadataUrl;
  final Map<String, dynamic> metadata;
}

class OAuthDiscoverySummary {
  OAuthDiscoverySummary({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.registrationEndpoint,
    this.issuer,
    this.resourceMetadataUrl,
    this.resourceMetadata,
    required this.availableAuthorizationServers,
    this.selectedAuthorizationServer,
    this.authorizationServerMetadataUrl,
    this.authorizationServerMetadata,
    this.scopeFromChallenge,
    this.recommendedScope,
  });

  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String? registrationEndpoint;
  final String? issuer;
  final String? resourceMetadataUrl;
  final Map<String, dynamic>? resourceMetadata;
  final List<String> availableAuthorizationServers;
  final String? selectedAuthorizationServer;
  final String? authorizationServerMetadataUrl;
  final Map<String, dynamic>? authorizationServerMetadata;
  final String? scopeFromChallenge;
  final String? recommendedScope;
}

class OAuthService {
  // Track active OAuth flow for cancellation
  static HttpServer? _activeServer;
  static StreamSubscription<HttpRequest>? _activeSubscription;
  static StreamSubscription<Uri?>? _activeLinkSubscription;
  static Completer<Map<String, dynamic>>? _activeCompleter;
  static Completer<Uri>? _activeRedirectCompleter;
  static Future<void>? _activeClosingFuture;
  static AppLinks? _appLinks;

  static const Duration _defaultFlowTimeout = Duration(minutes: 5);

  /// Cancel any active OAuth authorization flow and shut down the local server
  static Future<void> cancelActiveFlow() async {
    if (_activeServer != null ||
        _activeSubscription != null ||
        _activeLinkSubscription != null ||
        _activeCompleter != null ||
        _activeRedirectCompleter != null) {
      LoggerService.debug('OAuthService: Cancelling active OAuth flow');
      
      // Complete the completer with cancellation error if not already completed
      if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
        _activeCompleter!.completeError(Exception('OAuth flow cancelled by user'));
      }

      if (_activeRedirectCompleter != null && !_activeRedirectCompleter!.isCompleted) {
        _activeRedirectCompleter!
            .completeError(Exception('OAuth flow cancelled by user'));
      }
      
      // Save references before any async operations
      final server = _activeServer;
      final subscription = _activeSubscription;
      final linkSubscription = _activeLinkSubscription;
      final closingFuture = _activeClosingFuture;
      
      // Clear references immediately to prevent race conditions
      _activeServer = null;
      _activeSubscription = null;
      _activeLinkSubscription = null;
      _activeCompleter = null;
      _activeRedirectCompleter = null;
      _activeClosingFuture = null;
      
      // Wait for any in-progress closing operation
      if (closingFuture != null) {
        try {
          await closingFuture;
        } catch (_) {
          // Ignore errors from closing future
        }
      }
      
      // Close server and subscription if they weren't already closed
      if (server != null) {
        try {
          await server.close(force: true);
        } catch (_) {
          // Server may already be closed, ignore errors
        }
      }
      if (subscription != null) {
        try {
          await subscription.cancel();
        } catch (_) {
          // Subscription may already be cancelled, ignore errors
        }
      }
      if (linkSubscription != null) {
        try {
          await linkSubscription.cancel();
        } catch (_) {
          // Stream subscription may already be cancelled, ignore errors
        }
      }
    }
  }

  /// Perform full discovery workflow combining protected resource metadata and
  /// authorization server metadata resolution. Implements RFC 9728 + RFC 8414.
  static Future<OAuthDiscoverySummary> performDiscovery({
    required String baseUrl,
    String? metadataUrl,
    String? preferredAuthorizationServer,
  }) async {
    final baseUri = Uri.parse(baseUrl);
    final resourceResult = await _discoverResourceMetadata(
      baseUri: baseUri,
      metadataOverride: metadataUrl,
    );

    Map<String, dynamic>? resourceMetadata = resourceResult.metadata;
    final resourceMetadataUrl = resourceResult.metadataUrl;
    final scopeHint = resourceResult.scopeHint;
    final availableServers = List<String>.from(resourceResult.authorizationServers);

    Map<String, dynamic>? authorizationMetadata;
    String? authorizationMetadataUrl;
    String? issuer = resourceResult.issuer;
    String? selectedServer = preferredAuthorizationServer;

    if (resourceResult.isAuthorizationMetadata) {
      authorizationMetadata = resourceResult.authorizationMetadata;
      authorizationMetadataUrl = resourceResult.authorizationMetadataUrl;
      issuer = authorizationMetadata?['issuer'] as String? ?? issuer;
      selectedServer = issuer;
    } else {
      if (selectedServer == null || selectedServer.isEmpty) {
        if (availableServers.isNotEmpty) {
          selectedServer = availableServers.first;
        }
      }

      if (selectedServer == null || selectedServer.isEmpty) {
        final origin = Uri(
          scheme: baseUri.scheme,
          host: baseUri.host,
          port: baseUri.hasPort ? baseUri.port : null,
        );
        selectedServer = origin.toString();
      }

      final authResult = await discoverAuthorizationServerMetadata(issuer: selectedServer);
      authorizationMetadata = authResult.metadata;
      authorizationMetadataUrl = authResult.metadataUrl;
      issuer = authResult.issuer;
      selectedServer = authResult.issuer;
    }

    if (authorizationMetadata == null) {
      throw Exception('Failed to resolve authorization server metadata.');
    }

    final authorizationEndpoint = authorizationMetadata['authorization_endpoint'] as String?;
    final tokenEndpoint = authorizationMetadata['token_endpoint'] as String?;
    if (authorizationEndpoint == null || tokenEndpoint == null) {
      throw Exception('Authorization server metadata missing required endpoints.');
    }

    final registrationEndpoint = authorizationMetadata['registration_endpoint'] as String?;
    final recommendedScope = _determineScope(scopeHint, resourceMetadata, authorizationMetadata);

    return OAuthDiscoverySummary(
      authorizationEndpoint: authorizationEndpoint,
      tokenEndpoint: tokenEndpoint,
      registrationEndpoint: registrationEndpoint,
      issuer: issuer,
      resourceMetadataUrl: resourceMetadataUrl,
      resourceMetadata: resourceMetadata,
      availableAuthorizationServers: availableServers,
      selectedAuthorizationServer: selectedServer,
      authorizationServerMetadataUrl: authorizationMetadataUrl,
      authorizationServerMetadata: authorizationMetadata,
      scopeFromChallenge: scopeHint,
      recommendedScope: recommendedScope,
    );
  }

  static Future<ResourceDiscoveryResult> _discoverResourceMetadata({
    required Uri baseUri,
    String? metadataOverride,
  }) async {
    String? metadataUrl;
    Map<String, dynamic>? metadata;
    final servers = <String>{};
    String? scopeHint;
    bool isAuthorizationMetadata = false;
    Map<String, dynamic>? authorizationMetadata;
    String? authorizationMetadataUrl;
    String? issuer;

    if (metadataOverride != null && metadataOverride.trim().isNotEmpty) {
      final resolved = _resolveUri(baseUri, metadataOverride.trim());
      final json = await _fetchJsonIfSuccessful(resolved);
      if (json == null) {
        throw Exception('Failed to fetch metadata from ${resolved.toString()}');
      }
      if (_looksLikeAuthorizationMetadata(json)) {
        isAuthorizationMetadata = true;
        authorizationMetadata = json;
        authorizationMetadataUrl = resolved.toString();
        issuer = json['issuer'] as String? ?? resolved.toString();
      } else if (_looksLikeResourceMetadata(json)) {
        metadataUrl = resolved.toString();
        metadata = json;
        issuer = json['issuer'] as String?;
        servers.addAll(_extractAuthorizationServers(json['authorization_servers'], baseUri, resolved));
      } else {
        throw Exception('Metadata at ${resolved.toString()} is not recognized as protected resource or authorization server metadata.');
      }

      return ResourceDiscoveryResult(
        metadataUrl: metadataUrl,
        metadata: metadata,
        authorizationServers: servers.toList(),
        scopeHint: scopeHint,
        isAuthorizationMetadata: isAuthorizationMetadata,
        authorizationMetadata: authorizationMetadata,
        authorizationMetadataUrl: authorizationMetadataUrl,
        issuer: issuer,
      );
    }

    // Step 1: 401 challenge with WWW-Authenticate
    try {
      final response = await http.get(baseUri);
      if (response.statusCode == 401) {
        final header = response.headers['www-authenticate'];
        final metadataUri = _extractResourceMetadataUri(header, baseUri);
        scopeHint = _extractScopeFromHeader(header);
        if (metadataUri != null) {
          final json = await _fetchJsonIfSuccessful(metadataUri);
          if (json != null && _looksLikeResourceMetadata(json)) {
            metadataUrl = metadataUri.toString();
            metadata = json;
            issuer = json['issuer'] as String?;
            servers.addAll(_extractAuthorizationServers(json['authorization_servers'], baseUri, metadataUri));
          }
        }
      }
    } catch (e) {
      LoggerService.warning('OAuthService: Failed initial resource metadata request: $e');
    }

    // Step 2: Well-known URIs if not already resolved
    if (metadata == null) {
      for (final candidate in _resourceMetadataCandidates(baseUri)) {
        final json = await _fetchJsonIfSuccessful(candidate);
        if (json != null && _looksLikeResourceMetadata(json)) {
          metadataUrl = candidate.toString();
          metadata = json;
          issuer = json['issuer'] as String?;
          servers.addAll(_extractAuthorizationServers(json['authorization_servers'], baseUri, candidate));
          break;
        }
      }
    }

    return ResourceDiscoveryResult(
      metadataUrl: metadataUrl,
      metadata: metadata,
      authorizationServers: servers.toList(),
      scopeHint: scopeHint,
      isAuthorizationMetadata: isAuthorizationMetadata,
      authorizationMetadata: authorizationMetadata,
      authorizationMetadataUrl: authorizationMetadataUrl,
      issuer: issuer,
    );
  }

  static Future<AuthorizationServerMetadataResult> discoverAuthorizationServerMetadata({
    required String issuer,
  }) async {
    final issuerUri = Uri.parse(issuer);
    for (final candidate in _authorizationMetadataCandidates(issuerUri)) {
      final json = await _fetchJsonIfSuccessful(candidate);
      if (json != null && _looksLikeAuthorizationMetadata(json)) {
        final resolvedIssuer = json['issuer'] as String? ?? issuer;
        return AuthorizationServerMetadataResult(
          issuer: resolvedIssuer,
          metadataUrl: candidate.toString(),
          metadata: json,
        );
      }
    }
    throw Exception('Unable to resolve authorization server metadata for issuer $issuer');
  }

  static List<Uri> _resourceMetadataCandidates(Uri baseUri) {
    final candidates = <Uri>[];
    final trimmedPath = baseUri.path.replaceAll(RegExp(r'^/+|/+$'), '');
    if (trimmedPath.isNotEmpty) {
      candidates.add(Uri(
        scheme: baseUri.scheme,
        host: baseUri.host,
        port: baseUri.hasPort ? baseUri.port : null,
        path: '/.well-known/oauth-protected-resource/$trimmedPath',
      ));
    }
    candidates.add(Uri(
      scheme: baseUri.scheme,
      host: baseUri.host,
      port: baseUri.hasPort ? baseUri.port : null,
      path: '/.well-known/oauth-protected-resource',
    ));
    return candidates;
  }

  static List<Uri> _authorizationMetadataCandidates(Uri issuerUri) {
    final candidates = <Uri>[];
    final base = Uri(
      scheme: issuerUri.scheme,
      host: issuerUri.host,
      port: issuerUri.hasPort ? issuerUri.port : null,
    );
    final trimmedPath = issuerUri.path.replaceAll(RegExp(r'^/+|/+$'), '');

    if (trimmedPath.isNotEmpty) {
      candidates.add(base.replace(path: '/.well-known/oauth-authorization-server/$trimmedPath'));
      candidates.add(base.replace(path: '/.well-known/openid-configuration/$trimmedPath'));

      final normalized = issuerUri.path.endsWith('/')
          ? issuerUri.path.substring(0, issuerUri.path.length - 1)
          : issuerUri.path;
      final withPrefix = normalized.startsWith('/') ? normalized : '/$normalized';
      final appended = '$withPrefix/.well-known/openid-configuration';
      candidates.add(issuerUri.replace(path: appended, query: null, fragment: null));
    } else {
      candidates.add(base.replace(path: '/.well-known/oauth-authorization-server'));
      candidates.add(base.replace(path: '/.well-known/openid-configuration'));
    }
    return candidates;
  }

  static Uri _resolveUri(Uri baseUri, String value) {
    final candidate = Uri.parse(value);
    if (candidate.hasScheme) {
      return candidate;
    }
    return baseUri.resolve(value);
  }

  static bool _looksLikeAuthorizationMetadata(Map<String, dynamic> json) {
    return (json['authorization_endpoint'] ?? json['authorizationEndpoint']) != null &&
        (json['token_endpoint'] ?? json['tokenEndpoint']) != null;
  }

  static bool _looksLikeResourceMetadata(Map<String, dynamic> json) {
    return json['authorization_servers'] is List;
  }

  static Iterable<String> _extractAuthorizationServers(
    dynamic value,
    Uri baseUri,
    Uri metadataUri,
  ) {
    if (value is! List) return const <String>[];
    final results = <String>{};
    for (final entry in value) {
      if (entry is! String || entry.isEmpty) continue;
      try {
        final parsed = Uri.parse(entry);
        final resolved = parsed.hasScheme ? parsed : metadataUri.resolve(entry);
        if (resolved.hasScheme) {
          results.add(resolved.toString());
        }
      } catch (_) {
        // Ignore invalid URIs
      }
    }
    return results;
  }

  static String? _extractScopeFromHeader(String? header) {
    if (header == null) return null;
    final match = RegExp(r'scope="([^"]+)"', caseSensitive: false).firstMatch(header);
    return match?.group(1);
  }

  static Uri? _extractResourceMetadataUri(String? header, Uri baseUri) {
    if (header == null) return null;
    final match = RegExp(r'resource_metadata="([^"]+)"', caseSensitive: false).firstMatch(header);
    final value = match?.group(1);
    if (value == null || value.isEmpty) return null;
    return _resolveUri(baseUri, value);
  }

  static String? _determineScope(
    String? scopeHint,
    Map<String, dynamic>? resourceMetadata,
    Map<String, dynamic>? authorizationMetadata,
  ) {
    final hint = scopeHint?.trim();
    if (hint != null && hint.isNotEmpty) {
      return hint;
    }
    final resourceScopes = resourceMetadata?['scopes_supported'];
    if (resourceScopes is List) {
      final scopes = resourceScopes.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (scopes.isNotEmpty) {
        return scopes.join(' ');
      }
    }
    final authScopes = authorizationMetadata?['scopes_supported'];
    if (authScopes is List) {
      final scopes = authScopes.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (scopes.isNotEmpty) {
        return scopes.join(' ');
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _fetchJsonIfSuccessful(Uri uri) async {
    try {
      final response = await http.get(uri, headers: {'Accept': 'application/json'});
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      LoggerService.warning('OAuthService: Failed to fetch ${uri.toString()}: $e');
    }
    return null;
  }

  static Future<Map<String, dynamic>> fetchMetadata(String metadataUrl) async {
    final uri = Uri.parse(metadataUrl);
    final json = await _fetchJsonIfSuccessful(uri);
    if (json == null) {
      throw Exception('Metadata request failed for $metadataUrl');
    }
    return json;
  }

  /// Registers a dynamic client (RFC 7591) and returns the client credentials
  static Future<Map<String, String>> registerClient({
    required String registrationEndpoint,
    required String clientName,
    required String redirectUri,
    bool usePkce = true,
    String? scope,
  }) async {
    final metadata = {
      'client_name': clientName,
      'redirect_uris': [redirectUri],
      'grant_types': ['authorization_code', 'refresh_token'],
      'response_types': ['code'],
      'token_endpoint_auth_method': usePkce ? 'none' : 'client_secret_basic',
      if (scope != null && scope.isNotEmpty) 'scope': scope,
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

    await cancelActiveFlow();
    final redirectUri = OAuthRedirectHelper.resolve(config.redirectUri);

    if (OAuthRedirectHelper.usesCustomScheme) {
      return _authorizationCodeFlowWithDeepLink(
        config: config,
        state: state,
        verifier: verifier,
        codeChallenge: codeChallenge,
        redirectUri: redirectUri,
      );
    }

    return _authorizationCodeFlowWithLoopbackServer(
      config: config,
      state: state,
      verifier: verifier,
      codeChallenge: codeChallenge,
      redirectUri: redirectUri,
    );
  }

  static Future<Map<String, dynamic>> _authorizationCodeFlowWithLoopbackServer({
    required OAuthConfig config,
    required String state,
    required String redirectUri,
    String? verifier,
    String? codeChallenge,
  }) async {
    final uri = Uri.tryParse(redirectUri);
    if (uri == null) {
      throw Exception('Invalid redirect URI configured: $redirectUri');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw Exception('Redirect URI must be an http(s) loopback address when running on desktop. Got $redirectUri');
    }

    final callbackPath = uri.path.isEmpty ? '/' : uri.path;
    final port = uri.hasPort ? uri.port : Uri.parse(OAuthRedirectHelper.loopbackRedirectUri).port;

    late HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (e) {
      throw Exception('Unable to bind local redirect server on 127.0.0.1:$port. Ensure the port is free.');
    }

    _activeServer = server;

    final authParams = <String, String>{
      'response_type': 'code',
      'client_id': config.clientId,
      'redirect_uri': redirectUri,
      'state': state,
      if (config.usePkce && codeChallenge != null) 'code_challenge': codeChallenge,
      if (config.usePkce && codeChallenge != null) 'code_challenge_method': 'S256',
    };
    final trimmedScope = config.scope.trim();
    if (trimmedScope.isNotEmpty) {
      authParams['scope'] = trimmedScope;
    }
    final authUri = Uri.parse(config.authorizationEndpoint).replace(queryParameters: authParams);

    LoggerService.debug('OAuthService: Launching auth at: $authUri');
    await launchUrl(authUri, mode: LaunchMode.externalApplication);

    final completer = Completer<Map<String, dynamic>>();
    _activeCompleter = completer;
    bool handled = false;
    late StreamSubscription<HttpRequest> subscription;
    Future<void>? closingFuture;

    Future<void> ensureClosed() {
      closingFuture ??= () async {
        try {
          await server.close(force: true);
        } catch (_) {}
        try {
          await subscription.cancel();
        } catch (_) {}
        if (_activeServer == server) {
          _activeServer = null;
        }
        if (_activeSubscription == subscription) {
          _activeSubscription = null;
        }
        if (_activeCompleter == completer) {
          _activeCompleter = null;
        }
        _activeClosingFuture = null;
      }();
      _activeClosingFuture = closingFuture;
      return closingFuture!;
    }

    Future<void> respond(HttpRequest request, String body) async {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.html;
      request.response.write(body);
      await request.response.close();
    }

    subscription = server.listen((HttpRequest request) async {
      try {
        if (handled || request.uri.path != callbackPath) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }

        final params = Map<String, String>.from(request.uri.queryParameters);
        if (request.method.toUpperCase() == 'POST') {
          final contentType = request.headers.contentType;
          if (contentType == null || contentType.mimeType == 'application/x-www-form-urlencoded' ||
              contentType.mimeType == 'text/plain') {
            final body = await utf8.decoder.bind(request).join();
            if (body.isNotEmpty) {
              params.addAll(Uri.splitQueryString(body));
            }
          }
        }

        LoggerService.debug('OAuthService: Received callback with params: $params');

        final errorParam = params['error'];
        final errorDescription = params['error_description'] ?? params['errorDescription'];
        if (errorParam != null) {
          await respond(request,
              '<html><body>Authentication failed: $errorParam${errorDescription != null ? ' - $errorDescription' : ''}. You can close this window.</body></html>');
          await ensureClosed();
          if (!completer.isCompleted) {
            completer.completeError(Exception('Authorization server error: $errorParam${errorDescription != null ? ': $errorDescription' : ''}'));
          }
          return;
        }

        final code = params['code'];
        if (code == null || code.isEmpty) {
          await respond(request,
              '<html><body>Authentication response missing authorization code. You can close this window.</body></html>');
          await ensureClosed();
          if (!completer.isCompleted) {
            completer.completeError(Exception('Authorization response missing code'));
          }
          return;
        }

        final returnedState = params['state'];
        if (returnedState != null && returnedState != state) {
          await respond(request, '<html><body>State parameter mismatch. You can close this window.</body></html>');
          await ensureClosed();
          if (!completer.isCompleted) {
            completer.completeError(Exception('Authorization response state mismatch'));
          }
          return;
        }

        handled = true;
        await respond(request, '<html><body>You can close this window.</body></html>');

        LoggerService.debug('OAuthService: Callback received, waiting for app foreground before token exchange...');
        await Future.delayed(const Duration(milliseconds: 800));

        final tokenBody = <String, String>{
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
          final tokenUri = Uri.parse(config.tokenEndpoint);
          LoggerService.debug('OAuthService: Exchanging code for token at ${tokenUri.toString()}');
          final tokenResp = await _postWithRetry(
            uri: tokenUri,
            body: tokenBody,
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          );

          LoggerService.debug('OAuthService: Token exchange response status: ${tokenResp.statusCode}');

          if (tokenResp.statusCode >= 200 && tokenResp.statusCode < 300) {
            final tokenData = jsonDecode(tokenResp.body) as Map<String, dynamic>;
            final hasAccessToken = tokenData.containsKey('access_token');
            final hasRefreshToken = tokenData.containsKey('refresh_token');
            LoggerService.info(
              'OAuthService: Token exchange succeeded. Has access_token: $hasAccessToken, Has refresh_token: $hasRefreshToken',
            );
            if (!completer.isCompleted) {
              completer.complete(tokenData);
            } else {
              LoggerService.warning('OAuthService: Completer already completed, ignoring successful token response');
            }
          } else {
            LoggerService.error(
              'OAuthService: Token exchange failed with status ${tokenResp.statusCode}. Body: ${tokenResp.body}',
            );
            if (!completer.isCompleted) {
              completer.completeError(Exception('Token exchange failed (${tokenResp.statusCode}): ${tokenResp.body}'));
            } else {
              LoggerService.warning('OAuthService: Completer already completed, ignoring failed token response');
            }
          }
        } catch (e) {
          LoggerService.error('OAuthService: Token exchange error: $e');
          if (!completer.isCompleted) {
            completer.completeError(Exception('Network error contacting token endpoint: $e'));
          } else {
            LoggerService.warning('OAuthService: Completer already completed, ignoring token exchange error');
          }
        } finally {
          await ensureClosed();
        }
      } catch (e) {
        LoggerService.error('OAuthService: authorization flow error: $e');
        await ensureClosed();
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      }
    }, onError: (Object error, StackTrace stackTrace) async {
      LoggerService.error('OAuthService: Server listen error: $error');
      await ensureClosed();
      if (!completer.isCompleted) {
        completer.completeError(Exception('OAuth callback server error: $error'));
      }
    });

    _activeSubscription = subscription;

    try {
      final result = await completer.future.timeout(_defaultFlowTimeout);
      return result;
    } finally {
      await ensureClosed();
    }
  }

  static Future<Map<String, dynamic>> _authorizationCodeFlowWithDeepLink({
    required OAuthConfig config,
    required String state,
    required String redirectUri,
    String? verifier,
    String? codeChallenge,
  }) async {
    final authParams = <String, String>{
      'response_type': 'code',
      'client_id': config.clientId,
      'redirect_uri': redirectUri,
      'state': state,
      if (config.usePkce && codeChallenge != null) 'code_challenge': codeChallenge,
      if (config.usePkce && codeChallenge != null) 'code_challenge_method': 'S256',
    };
    final trimmedScope = config.scope.trim();
    if (trimmedScope.isNotEmpty) {
      authParams['scope'] = trimmedScope;
    }
    final authUri = Uri.parse(config.authorizationEndpoint).replace(queryParameters: authParams);

    LoggerService.debug('OAuthService: Launching auth with deep link redirect: $authUri');

    final completer = Completer<Map<String, dynamic>>();
    final redirectCompleter = Completer<Uri>();

    _activeCompleter = completer;
    _activeRedirectCompleter = redirectCompleter;

    void handleUri(Uri? uri) {
      if (uri == null || redirectCompleter.isCompleted) {
        return;
      }
      if (OAuthRedirectHelper.matchesRedirect(uri, redirectUri)) {
        redirectCompleter.complete(uri);
      }
    }

    final appLinks = _appLinks ??= AppLinks();

    StreamSubscription<Uri?>? subscription;
    try {
      subscription = appLinks.uriLinkStream.listen(handleUri, onError: (Object error) {
        LoggerService.error('OAuthService: Deep link stream error: $error');
      });
    } on Exception catch (e) {
      LoggerService.error('OAuthService: Unable to listen for deep link redirects: $e');
      throw Exception('Unable to listen for OAuth callback. Ensure app_links is configured correctly.');
    }

    _activeLinkSubscription = subscription;

    try {
      try {
        final initialUri = await appLinks.getInitialLink();
        handleUri(initialUri);
      } on PlatformException catch (e) {
        LoggerService.warning('OAuthService: Failed to obtain initial deep link URI: $e');
      } catch (e) {
        LoggerService.warning('OAuthService: Unexpected error obtaining initial deep link URI: $e');
      }

      final launched = await launchUrl(authUri, mode: LaunchMode.externalApplication);
      if (!launched) {
        throw Exception('Unable to open authorization URL.');
      }

      final callbackUri = await redirectCompleter.future.timeout(_defaultFlowTimeout);

      final params = Map<String, String>.from(callbackUri.queryParameters);
      if (callbackUri.fragment.isNotEmpty) {
        try {
          params.addAll(Uri.splitQueryString(callbackUri.fragment));
        } catch (e) {
          LoggerService.warning('OAuthService: Failed to parse fragment parameters: $e');
        }
      }

      LoggerService.debug('OAuthService: Received deep link callback with params: $params');

      final errorParam = params['error'];
      final errorDescription = params['error_description'] ?? params['errorDescription'];
      if (errorParam != null) {
        final message = 'Authorization server error: $errorParam${errorDescription != null ? ': $errorDescription' : ''}';
        if (!completer.isCompleted) {
          completer.completeError(Exception(message));
        }
        return await completer.future;
      }

      final code = params['code'];
      if (code == null || code.isEmpty) {
        if (!completer.isCompleted) {
          completer.completeError(Exception('Authorization response missing code'));
        }
        return await completer.future;
      }

      final returnedState = params['state'];
      if (returnedState != null && returnedState != state) {
        if (!completer.isCompleted) {
          completer.completeError(Exception('Authorization response state mismatch'));
        }
        return await completer.future;
      }

      LoggerService.debug('OAuthService: Waiting for app foreground before token exchange...');
      await Future.delayed(const Duration(milliseconds: 800));

      final tokenBody = <String, String>{
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
        final tokenUri = Uri.parse(config.tokenEndpoint);
        LoggerService.debug('OAuthService: Exchanging code for token at ${tokenUri.toString()}');
        final tokenResp = await _postWithRetry(
          uri: tokenUri,
          body: tokenBody,
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        );

        LoggerService.debug('OAuthService: Token exchange response status: ${tokenResp.statusCode}');

        if (tokenResp.statusCode >= 200 && tokenResp.statusCode < 300) {
          final tokenData = jsonDecode(tokenResp.body) as Map<String, dynamic>;
          final hasAccessToken = tokenData.containsKey('access_token');
          final hasRefreshToken = tokenData.containsKey('refresh_token');
          LoggerService.info(
            'OAuthService: Token exchange succeeded. Has access_token: $hasAccessToken, Has refresh_token: $hasRefreshToken',
          );
          if (!completer.isCompleted) {
            completer.complete(tokenData);
          } else {
            LoggerService.warning('OAuthService: Completer already completed, ignoring successful token response');
          }
        } else {
          LoggerService.error(
            'OAuthService: Token exchange failed with status ${tokenResp.statusCode}. Body: ${tokenResp.body}',
          );
          if (!completer.isCompleted) {
            completer.completeError(Exception('Token exchange failed (${tokenResp.statusCode}): ${tokenResp.body}'));
          } else {
            LoggerService.warning('OAuthService: Completer already completed, ignoring failed token response');
          }
        }
      } catch (e) {
        LoggerService.error('OAuthService: Token exchange error: $e');
        if (!completer.isCompleted) {
          completer.completeError(Exception('Network error contacting token endpoint: $e'));
        } else {
          LoggerService.warning('OAuthService: Completer already completed, ignoring token exchange error');
        }
      }

      final result = await completer.future.timeout(_defaultFlowTimeout);
      return result;
    } on TimeoutException catch (_) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Timed out waiting for OAuth authorization response.'));
      }
      rethrow;
    } finally {
      if (subscription != null) {
        try {
          await subscription.cancel();
        } catch (_) {}
      }
      if (_activeLinkSubscription == subscription) {
        _activeLinkSubscription = null;
      }
      if (_activeRedirectCompleter == redirectCompleter && !redirectCompleter.isCompleted) {
        redirectCompleter.completeError(Exception('OAuth flow cancelled internally.'));
      }
      if (_activeRedirectCompleter == redirectCompleter) {
        _activeRedirectCompleter = null;
      }
      if (_activeCompleter == completer && !completer.isCompleted) {
        completer.completeError(Exception('OAuth flow cancelled internally.'));
      }
      if (_activeCompleter == completer) {
        _activeCompleter = null;
      }
    }
  }

  static bool _isDnsFailure(dynamic error) {
    if (error is SocketException) {
      return error.message.contains('Failed host lookup') || 
             error.message.contains('Name or service not known') ||
             error.osError?.errorCode == 7; // errno = 7 is "No address associated with hostname"
    }
    if (error is http.ClientException) {
      final msg = error.toString().toLowerCase();
      return msg.contains('failed host lookup') || 
             msg.contains('no address associated with hostname') ||
             (error.uri != null && error.toString().contains('SocketException'));
    }
    return false;
  }

  static Future<http.Response> _postWithRetry({
    required Uri uri,
    required Map<String, String> body,
    Map<String, String>? headers,
    int maxAttempts = 3,
    Duration initialDelay = const Duration(milliseconds: 300),
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // Give Android DNS a brief moment to stabilize (already waited before calling this)
    await Future.delayed(const Duration(milliseconds: 200));
    
    var attempt = 0;
    Duration delayForAttempt(int attemptCount, bool isDns) {
      if (isDns) {
        // DNS failures need longer delays - Android network stack needs time
        final baseMs = 1000;
        final delayMs = (baseMs * attemptCount).clamp(1000, 5000);
        return Duration(milliseconds: delayMs);
      }
      final baseMs = initialDelay.inMilliseconds;
      final delayMs = (baseMs * attemptCount).clamp(200, 2000);
      return Duration(milliseconds: delayMs.round());
    }

    Exception? lastError;
    while (attempt < maxAttempts) {
      http.Client? client;
      try {
        attempt++;
        client = http.Client();
        LoggerService.debug('OAuthService: Token request attempt $attempt/$maxAttempts to ${uri.toString()}');
        
        final response = await client
            .post(uri, headers: headers, body: body)
            .timeout(timeout);
        
        LoggerService.info(
          'OAuthService: Token request attempt $attempt succeeded with status ${response.statusCode}',
        );
        
        // Close client on success
        client.close();
        return response;
      } on SocketException catch (e) {
        final isDns = _isDnsFailure(e);
        lastError = e;
        if (attempt >= maxAttempts) {
          if (client != null) {
            try {
              client.close();
            } catch (_) {}
          }
          rethrow;
        }
        LoggerService.warning(
          'OAuthService: Token request ${isDns ? "DNS" : "network"} error (attempt $attempt/$maxAttempts): $e. Retrying...',
        );
        if (client != null) {
          try {
            client.close();
          } catch (_) {}
        }
        await Future.delayed(delayForAttempt(attempt, isDns));
      } on TimeoutException catch (e) {
        lastError = e;
        if (attempt >= maxAttempts) {
          if (client != null) {
            try {
              client.close();
            } catch (_) {}
          }
          rethrow;
        }
        LoggerService.warning(
          'OAuthService: Token request timeout (attempt $attempt/$maxAttempts): $e. Retrying...',
        );
        if (client != null) {
          try {
            client.close();
          } catch (_) {}
        }
        await Future.delayed(delayForAttempt(attempt, false));
      } on http.ClientException catch (e) {
        final isDns = _isDnsFailure(e);
        lastError = e;
        if (attempt >= maxAttempts) {
          if (client != null) {
            try {
              client.close();
            } catch (_) {}
          }
          rethrow;
        }
        LoggerService.warning(
          'OAuthService: Token request ${isDns ? "DNS" : "client"} error (attempt $attempt/$maxAttempts): $e. Retrying...',
        );
        if (client != null) {
          try {
            client.close();
          } catch (_) {}
        }
        await Future.delayed(delayForAttempt(attempt, isDns));
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (client != null) {
          try {
            client.close();
          } catch (_) {}
        }
        if (attempt >= maxAttempts) {
          rethrow;
        }
        LoggerService.warning(
          'OAuthService: Token request unexpected error (attempt $attempt/$maxAttempts): $e. Retrying...',
        );
        await Future.delayed(delayForAttempt(attempt, false));
      }
    }
    
    throw lastError ?? Exception('Token request failed after $maxAttempts attempts');
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


