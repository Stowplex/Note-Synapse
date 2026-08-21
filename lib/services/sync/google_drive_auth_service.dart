// Google Drive OAuth — M2.9.
//
// Drives the authorization-code-with-PKCE consent flow for the
// `drive.file` scope and owns the resulting tokens. Everything mechanical
// (launching the browser, listening for the deep-link redirect, validating
// `state`, exchanging the code, retrying the token POST) is reused from
// `OAuthService.authorizationCodeFlow`; this class supplies only the
// Google-specific parts that generic OAuth machinery cannot know:
//
//   * Google's fixed endpoints (no RFC 8414 discovery round trip — Google
//     publishes an OpenID discovery document, but the two endpoints this
//     flow needs have been stable for years and fetching them on every
//     connect would be a needless network dependency at the exact moment
//     the user is least tolerant of one).
//   * `access_type=offline` + `prompt=consent`. **These are not optional.**
//     Google issues a refresh token ONLY when `access_type=offline` is
//     present, and (for a client the user has already granted) only re-issues
//     one when `prompt=consent` forces the consent screen again. Without
//     them the connection dies silently about an hour after setup, and
//     `OAuthTokenManager.refreshNow()` fails with "no refresh token stored".
//   * The reversed-client-ID redirect, passed as `redirectUriOverride` so
//     that `OAuthRedirectHelper.resolve()` — which would rewrite it to
//     `notesynapse://oauth/callback` on mobile — never sees it. See that
//     parameter's doc comment on `OAuthService.authorizationCodeFlow`.
//
// **Token storage.** `OAuthTokenManager` with `storagePrefix:
// 'gdrive_oauth_'` (the parameter added in M2.2 for precisely this) and a
// fixed `endpointId`, so Drive tokens live in their own secure-storage key
// namespace and can never collide with, or be mistaken for, an MCP
// endpoint's tokens.
//
// **What is deliberately absent.** No Google Play Services, no
// `google_sign_in`, no Firebase, no Credential Manager, no AppAuth — locked-in
// product requirement 12 forbids any GMS dependency. This flow is plain
// HTTPS plus a custom URL scheme, built from packages already in
// `pubspec.yaml` (`url_launcher`, `app_links`, `http`, `crypto`).
// `test/no_gms_dependency_audit_test.dart` guards that.

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../models/mcp_endpoint.dart';
import '../logger_service.dart';
import '../oauth_service.dart';
import '../oauth_token_manager.dart';
import 'google_drive_client_config.dart';

/// The Drive OAuth connection as the UI needs to see it.
enum GoogleDriveConnectionState {
  /// This build variant has no real client ID compiled in — connecting is
  /// impossible until a developer fills one in.
  notConfigured,

  /// Configured, but the user has never completed consent (or has
  /// disconnected since).
  disconnected,

  /// Consent completed and a refresh token is stored — the normal state.
  connected,

  /// Consent completed but NO refresh token was stored. Usable until the
  /// access token expires (~1h) and then not recoverable without
  /// re-consenting; surfaced distinctly so it is diagnosable rather than
  /// appearing as a random failure an hour later.
  connectedWithoutRefreshToken,
}

class GoogleDriveAuthService {
  GoogleDriveAuthService({OAuthTokenManager? tokenManager})
    : _injectedTokenManager = tokenManager;

  /// Google's authorization endpoint (OAuth 2.0 v2).
  static const String authorizationEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';

  /// Google's token endpoint.
  static const String tokenEndpoint = 'https://oauth2.googleapis.com/token';

  /// Per-file Drive scope: this app sees only files it created itself.
  /// Narrowest scope that supports the whole `GoogleDriveBackend` design
  /// (which creates and owns its own root folder), and the one that keeps
  /// this app out of Google's restricted-scope verification process.
  static const String scope = 'https://www.googleapis.com/auth/drive.file';

  /// Secure-storage key namespace for Drive tokens.
  static const String storagePrefix = 'gdrive_oauth_';

  /// Stable identity for the single Drive "endpoint" (there is exactly one;
  /// unlike MCP, Drive is not a user-configurable list of servers).
  static const String endpointId = 'google_drive_sync';

  /// Google-specific query parameters added to the authorization request.
  ///
  /// A named constant rather than an inline literal inside [connect] so that
  /// there is exactly one definition and a test can assert against the same
  /// object production uses — see [consentAuthorizationUri] and
  /// `test/services/google_drive_auth_service_test.dart`. The failure this
  /// guards against is silent and delayed: drop `access_type=offline` (or
  /// `prompt=consent`, for a user who has already granted this client) and
  /// Google returns no refresh token, everything works for about an hour,
  /// and then sync fails permanently with "no refresh token stored".
  static const Map<String, String> consentParams = {
    'access_type': 'offline',
    'prompt': 'consent',
    // Keeps any scope the user has already granted this client instead of
    // narrowing the grant to just `drive.file` on re-consent.
    'include_granted_scopes': 'true',
  };

  final OAuthTokenManager? _injectedTokenManager;
  OAuthTokenManager? _cachedTokenManager;

  /// The OAuth client configuration for the running build variant. PKCE on,
  /// no client secret.
  OAuthConfig get config => OAuthConfig(
    authorizationEndpoint: authorizationEndpoint,
    tokenEndpoint: tokenEndpoint,
    clientId: GoogleDriveClientConfig.clientId,
    scope: scope,
    usePkce: true,
    redirectUri: GoogleDriveClientConfig.redirectUri,
    issuer: 'https://accounts.google.com',
  );

  /// The token manager backing every Drive API call. One instance per
  /// service instance so `OAuthTokenManager`'s in-flight-refresh
  /// de-duplication (which is per-instance) actually de-duplicates across
  /// the concurrent Drive requests `GoogleDriveBackend` issues.
  OAuthTokenManager get tokenManager =>
      _injectedTokenManager ??
      (_cachedTokenManager ??= OAuthTokenManager(
        endpointId: endpointId,
        config: config,
        storagePrefix: storagePrefix,
        redirectUriOverride: GoogleDriveClientConfig.redirectUri,
      ));

  /// Current connection state, without any network round trip.
  Future<GoogleDriveConnectionState> connectionState() async {
    if (!GoogleDriveClientConfig.isConfigured) {
      return GoogleDriveConnectionState.notConfigured;
    }
    final manager = tokenManager;
    if (await manager.hasRefreshToken()) {
      return GoogleDriveConnectionState.connected;
    }
    if (await manager.hasStoredCredentials()) {
      return GoogleDriveConnectionState.connectedWithoutRefreshToken;
    }
    return GoogleDriveConnectionState.disconnected;
  }

  /// True on the platforms that can actually receive this flow's redirect.
  ///
  /// The redirect is a private-use URL scheme delivered as a deep link, and
  /// only the Android manifest (`${googleReversedClientId}` intent-filter)
  /// and iOS `Info.plist` (`CFBundleURLSchemes`) register it. Note Synapse
  /// ships Android + iOS only, so this is not a gap so much as a boundary —
  /// but the boundary has to be checked, because crossing it fails in a
  /// maximally unhelpful way (see [connect]).
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  /// Runs the full consent flow and stores the resulting tokens.
  ///
  /// Throws [GoogleDriveClientNotConfiguredException] if this build has no
  /// real client ID, [UnsupportedError] on a platform that cannot receive
  /// the redirect, and whatever `OAuthService.authorizationCodeFlow` throws
  /// otherwise (user cancellation, timeout, `error=access_denied` from
  /// Google, token-exchange failure). Callers are expected to surface the
  /// message; nothing here swallows a failure.
  ///
  /// **Shared global flow state.** `OAuthService` tracks the active
  /// authorization flow in *static* fields, and
  /// `authorizationCodeFlow` begins by calling
  /// `OAuthService.cancelActiveFlow()`. There is therefore at most one
  /// OAuth flow in the whole app at any time: starting Drive consent
  /// cancels an in-progress MCP consent, and vice versa (the cancelled one
  /// fails with "OAuth flow cancelled by user"). Not reachable today — both
  /// flows are started from separate settings screens by a human tapping a
  /// button — but it is a real property of the shared machinery, not an
  /// oversight, and anything that ever starts a flow programmatically or in
  /// the background must account for it. Pre-existing; M2.9 did not
  /// introduce it and deliberately did not refactor the MCP-shared static
  /// state to fix it.
  Future<void> connect() async {
    GoogleDriveClientConfig.assertConfigured();

    if (!isSupportedPlatform) {
      // Fail immediately instead of proceeding: the deep-link branch would
      // launch a browser, then wait on an `app_links` stream that can never
      // produce this scheme's callback on a platform where nothing
      // registered it — a silent five-minute spinner ending in a bare
      // TimeoutException. An immediate, explanatory error is strictly more
      // useful than an accurate-but-unactionable one five minutes later.
      throw UnsupportedError(
        'Google Drive sync is only available on Android and iOS. The OAuth '
        'redirect uses a private-use URL scheme that only those platforms '
        'register (Android manifest intent-filter / iOS CFBundleURLSchemes), '
        'so consent could never complete here.',
      );
    }

    final state = _randomState();
    LoggerService.info(
      'GoogleDriveAuthService: starting consent flow '
      '(redirect ${GoogleDriveClientConfig.redirectUri})',
    );

    final tokens = await OAuthService.authorizationCodeFlow(
      config: config,
      state: state,
      redirectUriOverride: GoogleDriveClientConfig.redirectUri,
      extraAuthorizationParams: consentParams,
    );

    await tokenManager.saveTokens(tokens);

    if (tokens['refresh_token'] == null) {
      // Not fatal right now (the access token works), but it means the
      // connection will expire in about an hour with no way back except
      // re-consenting — worth a loud log line so it is diagnosable if a
      // user reports "sync worked once".
      LoggerService.warning(
        'GoogleDriveAuthService: Google returned no refresh_token. Sync will '
        'stop working when the access token expires. This usually means the '
        'authorization request lost access_type=offline / prompt=consent.',
      );
    } else {
      LoggerService.info('GoogleDriveAuthService: consent complete');
    }
  }

  /// The exact URL [connect] sends the user's browser to, built from the
  /// same `config`/redirect/[consentParams] that [connect] passes to
  /// `OAuthService.authorizationCodeFlow`.
  ///
  /// Exists so a test can assert the authorization request's contents
  /// without launching a browser or completing a flow. [state] and
  /// [codeChallenge] are generated inside `OAuthService` at flow time and
  /// are irrelevant to what this is used to check, so they are parameters
  /// here rather than regenerated.
  @visibleForTesting
  Uri consentAuthorizationUri({
    String state = 'test-state',
    String? codeChallenge = 'test-challenge',
  }) => OAuthService.buildAuthorizationUri(
    config: config,
    state: state,
    redirectUri: GoogleDriveClientConfig.redirectUri,
    codeChallenge: codeChallenge,
    extraAuthorizationParams: consentParams,
  );

  /// Clears stored Drive tokens.
  ///
  /// Local-only: this does not call Google's revocation endpoint, so the
  /// grant remains listed under the user's Google account until they remove
  /// it at myaccount.google.com. Nor does it touch anything already written
  /// to Drive, or any local sync state — reconnecting the same account
  /// resumes against the same dataset.
  ///
  /// **Known residual (M2.9): connecting a DIFFERENT Google account after
  /// disconnecting is not properly supported.** Local sync state (device
  /// log frontier, seq counters, `dataset_bootstrap_status`) is scoped to
  /// the dataset, not to the account, and none of it is cleared here.
  /// `DatasetBootstrap` partly self-heals — it re-reads the marker from the
  /// backend and re-runs the create-or-join sequence when the new account's
  /// Drive has none — but the retained frontier would still describe the
  /// old dataset's commits. Proper account switching (or dataset reset)
  /// needs its own milestone; do not present this as an account switcher.
  Future<void> disconnect() async {
    await tokenManager.clear();
    LoggerService.info('GoogleDriveAuthService: disconnected (tokens cleared)');
  }

  static String _randomState() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
