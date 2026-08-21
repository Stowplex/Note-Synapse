import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mcp_endpoint.dart';
import 'logger_service.dart';
import 'oauth_redirect_helper.dart';
import 'network_provider.dart';

/// Thrown by [OAuthTokenManager.refreshNow] when a forced refresh fails.
///
/// [requiresReauthorization] distinguishes "the user must go through the
/// consent flow again" (no refresh token stored, or the token endpoint
/// rejected the refresh token itself — typically an `invalid_grant` error,
/// § 8.2 fault-injection item 11 / `SyncRefreshTokenRevokedException`) from
/// a transient failure (network error, 5xx from the token endpoint) that's
/// worth surfacing as an ordinary network problem instead. Deliberately a
/// plain `Exception`, not one of `sync_backend_exceptions.dart`'s types —
/// this class has no dependency on, or knowledge of, `SyncBackend` at all
/// (it predates it and is also used by `McpService`); callers that need
/// the `Sync*Exception` vocabulary (`GoogleDriveBackend`) are expected to
/// catch this and translate it themselves, which is exactly what
/// `GoogleDriveBackend._forceRefreshOrThrow` does.
class OAuthRefreshFailedException implements Exception {
  final String message;
  final bool requiresReauthorization;
  const OAuthRefreshFailedException(
    this.message, {
    this.requiresReauthorization = false,
  });
  @override
  String toString() =>
      'OAuthRefreshFailedException: $message'
      '${requiresReauthorization ? ' (reauthorization required)' : ''}';
}

/// Manages OAuth tokens (access/refresh/id) for a single endpoint.
/// Stores tokens securely and refreshes them as needed.
///
/// **Storage-key prefix, M2.2 refactor (§ Architecture 8.3):** the four
/// underlying storage-key prefixes used to be hardcoded, literally
/// MCP-branded strings (`mcp_oauth_token_` etc.) — fine while `McpService`
/// was the only consumer, but a real problem the moment a second, unrelated
/// feature (Drive sync auth) needs its own `OAuthTokenManager` instance:
/// without this refactor, a Drive-auth consumer would either collide with
/// MCP's storage keys (if it reused the same `endpointId`, e.g. by
/// accident) or be forced to synthesize a fake "endpoint" purely to get a
/// distinct key, both of which bake an MCP-specific name permanently into
/// what is now a dual-purpose class. [storagePrefix] parametrizes this;
/// the default (`'mcp_oauth_'`) reproduces the exact previous key strings
/// byte-for-byte (`'mcp_oauth_' + 'token_' == 'mcp_oauth_token_'`, etc.), so
/// `McpService`'s existing usage — which never passes this parameter — is
/// completely unaffected: no key migration, no behavior change. A Drive
/// consumer passes e.g. `storagePrefix: 'gdrive_oauth_'` to get its own,
/// non-colliding, non-confusing key namespace.
class OAuthTokenManager {
  static const _defaultStoragePrefix = 'mcp_oauth_';

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

  final String _tokenPrefix;
  final String _refreshPrefix;
  final String _idTokenPrefix;
  final String _expiryPrefix;

  /// Injectable so tests can exercise the refresh flow (including
  /// [refreshNow], § 8.3's new refresh-on-401 support) without a real
  /// network stack / `NetworkProvider.init()`. Defaults to
  /// `NetworkProvider.post`, matching this class's behavior before this
  /// parameter existed.
  final Future<http.Response> Function(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  })
  _httpPost;

  /// M2.9: when non-null, used verbatim as the `redirect_uri` sent with the
  /// refresh-token grant instead of `OAuthRedirectHelper.resolve(...)`.
  /// Same reasoning as `OAuthService.authorizationCodeFlow`'s override of
  /// the same name: `resolve()` rewrites any unrecognized scheme to
  /// `notesynapse://oauth/callback` on mobile, which would make the Drive
  /// refresh request advertise a redirect URI that is not the one the
  /// authorization code was actually issued against. `null` (the default,
  /// and what `McpService` passes) preserves the previous behavior exactly.
  final String? _redirectUriOverride;

  OAuthTokenManager({
    required this.endpointId,
    required this.config,
    String storagePrefix = _defaultStoragePrefix,
    String? redirectUriOverride,
    Future<http.Response> Function(
      Uri url, {
      Map<String, String>? headers,
      Object? body,
    })?
    httpPost,
  }) : _tokenPrefix = '${storagePrefix}token_',
       _refreshPrefix = '${storagePrefix}refresh_',
       _idTokenPrefix = '${storagePrefix}id_',
       _expiryPrefix = '${storagePrefix}expiry_',
       _redirectUriOverride = redirectUriOverride,
       _httpPost = httpPost ?? NetworkProvider.post;

  /// True iff this manager currently holds any stored credential for
  /// [endpointId] — i.e. the consent flow has completed at least once and
  /// has not been cleared since. Deliberately does NOT trigger a refresh
  /// (unlike [getAccessToken]), so UI can ask "is this connected?" without
  /// a network round trip or a chance of clearing state as a side effect.
  Future<bool> hasStoredCredentials() async {
    final refresh = await _readSecure(_refreshPrefix);
    if (refresh != null && refresh.isNotEmpty) return true;
    final access = await _readSecure(_tokenPrefix);
    return access != null && access.isNotEmpty;
  }

  /// True iff a refresh token specifically is stored. A connection with an
  /// access token but no refresh token works only until the access token
  /// expires (~1 hour for Google) — worth surfacing distinctly, since the
  /// usual cause is a consent request that omitted `access_type=offline`.
  Future<bool> hasRefreshToken() async {
    final refresh = await _readSecure(_refreshPrefix);
    return refresh != null && refresh.isNotEmpty;
  }

  /// Returns a valid access token, refreshing if needed.
  Future<String?> getAccessToken() async {
    try {
      final expiryIso = await _readSecure(_expiryPrefix);
      if (expiryIso != null) {
        final expiry = DateTime.tryParse(expiryIso);
        if (expiry != null &&
            DateTime.now().isAfter(
              expiry.subtract(const Duration(seconds: 30)),
            )) {
          // Best-effort proactive refresh — failures are swallowed here
          // exactly as before this refactor (this path runs ahead of any
          // actual API call, so there's nothing yet to retry against; a
          // caller that then gets a 401 anyway is expected to use
          // [refreshNow] instead, which does surface failures).
          //
          // **Goes through [refreshNow], not `_refreshToken` directly
          // (fixed in M2.9 review).** This path used to call
          // `_refreshToken(throwOnFailure: false)`, which bypassed
          // [_inFlightRefresh] entirely — so the concurrency guard M2.2
          // added to [refreshNow] did not protect the far more frequent
          // path. `GoogleDriveBackend` calls `getAccessToken()` on *every*
          // Drive request, and issues requests concurrently, so an expired
          // token meant N simultaneous requests each firing their own
          // refresh-token round trip. That is not merely wasteful: Google
          // rotates refresh tokens and runs reuse detection, and a second
          // refresh using a token the first has already superseded can be
          // read as token theft and revoke the whole grant. Routing through
          // [refreshNow] makes all of them await one shared refresh; the
          // try/catch preserves the best-effort semantics this call site
          // has always had.
          try {
            await refreshNow();
          } catch (_) {
            // Swallowed by design — see above.
          }
        }
      }

      return await _readSecure(_tokenPrefix);
    } catch (e) {
      LoggerService.error('OAuthTokenManager: error getting access token: $e');
      return null;
    }
  }

  /// Forces a token refresh, bypassing the cached-expiry check entirely —
  /// § 8.3's refresh-on-401 requirement. Unlike the proactive refresh
  /// inside [getAccessToken] (best-effort, failures swallowed, since it
  /// runs speculatively before any real call has been attempted), this
  /// throws [OAuthRefreshFailedException] on failure so a caller that just
  /// received a 401 from a real API call can distinguish "refresh worked,
  /// retry the call" from "refresh failed — surface a real auth error"
  /// (and, via [OAuthRefreshFailedException.requiresReauthorization],
  /// which kind of auth error).
  ///
  /// **Design decision, documented per the M2.2 brief's request:** the
  /// retry-the-failed-call-once behavior itself does *not* live here — it
  /// lives in the caller (`GoogleDriveBackend._authorizedRequest`).
  /// `OAuthTokenManager` has no concept of "the call that just failed" (it
  /// only ever deals in tokens, not in arbitrary HTTP requests/responses),
  /// so baking retry-on-401 into this class would mean teaching it HTTP
  /// semantics — status codes, request replay — it has no other reason to
  /// know about, for the benefit of exactly one caller. Keeping this class
  /// to "force a refresh, tell me if it worked" and letting the caller own
  /// "what to do about a 401" keeps the coupling one-directional: any
  /// future `SyncBackend`/API-calling code can reuse this same method
  /// without `OAuthTokenManager` needing to know anything about them.
  ///
  /// **Concurrency guard, added in review:** a caller issuing several
  /// requests in parallel (e.g. `GoogleDriveBackend` uploading multiple
  /// blobs concurrently) can have more than one of them independently
  /// observe a 401 around the same time. Without de-duplication here, each
  /// would trigger its own full refresh-token HTTP round trip — wasteful
  /// at minimum, and a real risk with Google's refresh-token rotation/
  /// reuse-detection, which can treat a second, unnecessary refresh using
  /// a token already superseded by the first as a signal of token theft.
  /// [_inFlightRefresh] makes every concurrent caller await the *same*
  /// underlying refresh instead: the first call starts it and stores the
  /// `Future`; any call that arrives before that `Future` completes gets
  /// the same instance back (and therefore the same outcome — success or
  /// the same exception) rather than starting a second HTTP call.
  Future<String> refreshNow() {
    final inFlight = _inFlightRefresh;
    if (inFlight != null) return inFlight;

    final future = _doRefreshNow();
    _inFlightRefresh = future;
    // Clear the slot once this refresh settles (success or failure) so the
    // *next* refreshNow() call — which by definition is not part of this
    // batch of concurrent callers — starts a fresh refresh rather than
    // permanently reusing a stale result.
    unawaited(
      future.then(
        (_) => _clearInFlightRefresh(future),
        onError: (_) => _clearInFlightRefresh(future),
      ),
    );
    return future;
  }

  void _clearInFlightRefresh(Future<String> future) {
    if (identical(_inFlightRefresh, future)) {
      _inFlightRefresh = null;
    }
  }

  Future<String>? _inFlightRefresh;

  Future<String> _doRefreshNow() async {
    await _refreshToken(throwOnFailure: true);
    final token = await _readSecure(_tokenPrefix);
    if (token == null || token.isEmpty) {
      throw const OAuthRefreshFailedException(
        'refresh reported success but no access token was stored afterward',
      );
    }
    return token;
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

  /// Returns true iff [response] looks like the token endpoint rejecting
  /// the refresh token itself (RFC 6749 `invalid_grant`), as opposed to a
  /// transient failure — the signal [refreshNow] uses to set
  /// [OAuthRefreshFailedException.requiresReauthorization].
  bool _looksLikeInvalidGrant(http.Response response) {
    if (response.statusCode != 400 && response.statusCode != 401) {
      return false;
    }
    try {
      final data = jsonDecode(response.body);
      return data is Map && data['error'] == 'invalid_grant';
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshToken({required bool throwOnFailure}) async {
    try {
      final refreshToken = await _readSecure(_refreshPrefix);
      if (refreshToken == null || refreshToken.isEmpty) {
        if (throwOnFailure) {
          throw const OAuthRefreshFailedException(
            'no refresh token stored',
            requiresReauthorization: true,
          );
        }
        return;
      }

      final body = {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': config.clientId,
        'redirect_uri':
            _redirectUriOverride ??
            OAuthRedirectHelper.resolve(config.redirectUri),
      };
      if (!config.usePkce &&
          config.clientSecret != null &&
          config.clientSecret!.isNotEmpty) {
        body['client_secret'] = config.clientSecret!;
      }

      final response = await _httpPost(
        Uri.parse(config.tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: body,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        await saveTokens(data);
      } else {
        LoggerService.warning(
          'OAuthTokenManager: refresh failed ${response.statusCode}: ${response.body}',
        );
        if (throwOnFailure) {
          throw OAuthRefreshFailedException(
            'refresh failed (${response.statusCode}): ${response.body}',
            requiresReauthorization: _looksLikeInvalidGrant(response),
          );
        }
      }
    } on OAuthRefreshFailedException {
      rethrow;
    } catch (e) {
      LoggerService.error('OAuthTokenManager: error refreshing token: $e');
      if (throwOnFailure) {
        throw OAuthRefreshFailedException('error refreshing token: $e');
      }
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
