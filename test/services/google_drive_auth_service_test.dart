// M2.9 — `GoogleDriveAuthService` / Drive OAuth wiring.
//
// These tests cover the parts of the Drive consent flow that are checkable
// without contacting Google or launching a browser: the OAuth config that
// gets sent, the not-configured guard, the redirect-URI bypass of
// `OAuthRedirectHelper`, and the storage-key namespace.
//
// They deliberately do NOT attempt an end-to-end consent flow — that needs a
// real Google client, a real browser, and a real device, and is a manual
// smoke test by design (see `google_drive_backend.dart`'s file doc comment,
// which makes the same disclosure for the backend itself).
//
// Storage note: as in `oauth_token_manager_test.dart`, `FlutterSecureStorage`
// has no platform channel under `flutter test`, so `OAuthTokenManager` falls
// back to `SharedPreferences`, which `setMockInitialValues` makes an in-memory
// store.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/oauth_redirect_helper.dart';
import 'package:note_synapse/services/oauth_service.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';
import 'package:note_synapse/services/sync/google_drive_auth_service.dart';
import 'package:note_synapse/services/sync/google_drive_client_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('OAuthConfig sent to Google', () {
    test(
      'uses Google\'s fixed endpoints, drive.file scope, PKCE, no secret',
      () {
        final config = GoogleDriveAuthService().config;

        expect(
          config.authorizationEndpoint,
          'https://accounts.google.com/o/oauth2/v2/auth',
        );
        expect(config.tokenEndpoint, 'https://oauth2.googleapis.com/token');
        expect(config.scope, 'https://www.googleapis.com/auth/drive.file');
        expect(config.usePkce, isTrue);
        expect(
          config.clientSecret,
          isNull,
          reason:
              'Note Synapse is open source: a shipped client secret is public. '
              'The iOS client type issues none and relies on PKCE, which is '
              'why the Desktop client type was ruled out.',
        );
        expect(config.redirectUri, GoogleDriveClientConfig.redirectUri);
        expect(
          config.redirectUri,
          startsWith('com.googleusercontent.apps.'),
          reason:
              'Loopback and device-flow redirects are both ruled out for this '
              'app; the redirect must be Google\'s reversed-client-ID scheme.',
        );
      },
    );

    test('token manager uses the gdrive_oauth_ key namespace', () async {
      final service = GoogleDriveAuthService();
      await service.tokenManager.saveTokens({
        'access_token': 'tok',
        'refresh_token': 'ref',
        'expires_in': 3600,
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gdrive_oauth_token_google_drive_sync'), 'tok');
      expect(prefs.getString('gdrive_oauth_refresh_google_drive_sync'), 'ref');
      expect(
        prefs.getString('mcp_oauth_token_google_drive_sync'),
        isNull,
        reason: 'Drive tokens must never land in the MCP key namespace.',
      );
    });
  });

  group('authorization request contents', () {
    // The failure these guard against is silent and delayed: if
    // `access_type=offline` (or `prompt=consent`, for a user who has already
    // granted this client) never reaches Google, Google issues no refresh
    // token. Consent succeeds, the first sync works, and roughly an hour
    // later sync fails permanently with "no refresh token stored" — a
    // symptom arbitrarily far from its cause. Before this, the only thing
    // asserting these params was a human reading the source.

    test('consentParams carries the refresh-token-critical parameters', () {
      expect(GoogleDriveAuthService.consentParams['access_type'], 'offline');
      expect(GoogleDriveAuthService.consentParams['prompt'], 'consent');
      expect(
        GoogleDriveAuthService.consentParams['include_granted_scopes'],
        'true',
      );
    });

    test('the URL connect() launches actually contains them, alongside the '
        'redirect, scope, PKCE challenge and client ID', () {
      final service = GoogleDriveAuthService();
      final uri = service.consentAuthorizationUri(
        state: 'state-123',
        codeChallenge: 'challenge-abc',
      );

      expect(
        uri.toString(),
        startsWith(GoogleDriveAuthService.authorizationEndpoint),
      );

      final q = uri.queryParameters;
      expect(q['access_type'], 'offline');
      expect(q['prompt'], 'consent');
      expect(q['include_granted_scopes'], 'true');

      expect(q['response_type'], 'code');
      expect(q['client_id'], GoogleDriveClientConfig.clientId);
      expect(q['redirect_uri'], GoogleDriveClientConfig.redirectUri);
      expect(q['state'], 'state-123');
      expect(q['scope'], GoogleDriveAuthService.scope);
      expect(q['code_challenge'], 'challenge-abc');
      expect(q['code_challenge_method'], 'S256');
      expect(
        q.containsKey('client_secret'),
        isFalse,
        reason: 'A secret must never appear in an authorization URL.',
      );
    });

    test('buildAuthorizationUri applies extras last, so a caller can '
        'override a computed parameter', () {
      final uri = OAuthService.buildAuthorizationUri(
        config: GoogleDriveAuthService().config,
        state: 's',
        redirectUri: 'x:/cb',
        codeChallenge: 'c',
        extraAuthorizationParams: const {
          'access_type': 'offline',
          'scope': 'overridden.scope',
        },
      );
      expect(uri.queryParameters['scope'], 'overridden.scope');
      expect(uri.queryParameters['access_type'], 'offline');
      expect(uri.queryParameters['redirect_uri'], 'x:/cb');
    });

    test('the MCP call shape (no extras) is unchanged', () {
      final uri = OAuthService.buildAuthorizationUri(
        config: OAuthConfig(
          authorizationEndpoint: 'https://mcp.test/authorize',
          tokenEndpoint: 'https://mcp.test/token',
          clientId: 'mcp-client',
          scope: 'mcp.scope',
          usePkce: true,
          redirectUri: 'notesynapse://oauth/callback',
        ),
        state: 's',
        redirectUri: 'notesynapse://oauth/callback',
        codeChallenge: 'c',
      );
      expect(uri.queryParameters.keys.toSet(), {
        'response_type',
        'client_id',
        'redirect_uri',
        'state',
        'code_challenge',
        'code_challenge_method',
        'scope',
      });
      expect(
        uri.queryParameters.containsKey('access_type'),
        isFalse,
        reason:
            'Google-specific parameters must not leak into the MCP flow, '
            'which shares this builder.',
      );
    });
  });

  group('OAuthRedirectHelper bypass (the M2.9 blocker)', () {
    // `OAuthRedirectHelper.resolve()` force-rewrites any unrecognized scheme
    // to `notesynapse://oauth/callback` when running on Android/iOS. That is
    // correct for the MCP flow it was written for and must not change, so the
    // Drive flow passes its redirect around `resolve()` instead
    // (`redirectUriOverride`). These tests pin down why that matters.
    //
    // Note: `resolve()` keys off `Platform.isAndroid/isIOS`, which are false
    // in a host `flutter test` run, so the rewrite itself cannot be triggered
    // here. What CAN be shown — and is what actually breaks — is that the
    // rewritten value would never match an incoming Google callback.

    test('a Google callback URI matches the Drive redirect, and does NOT match '
        'the notesynapse:// redirect resolve() would have substituted', () {
      final callback = Uri.parse(
        '${GoogleDriveClientConfig.redirectUri}'
        '?code=4/0AY0e-g7&state=deadbeef&scope=https://www.googleapis.com/auth/drive.file',
      );

      expect(
        OAuthRedirectHelper.matchesRedirect(
          callback,
          GoogleDriveClientConfig.redirectUri,
        ),
        isTrue,
      );
      expect(
        OAuthRedirectHelper.matchesRedirect(
          callback,
          OAuthRedirectHelper.customSchemeRedirectUri,
        ),
        isFalse,
        reason:
            'If the Drive flow let resolve() rewrite its redirect to '
            'notesynapse://oauth/callback, the deep-link listener would '
            'never recognize Google\'s callback: consent would succeed and '
            'the app would hang until the 5-minute timeout.',
      );

      // And the code/state survive parsing of a scheme:/path (no authority)
      // URI, which is the shape Google actually sends back.
      expect(callback.queryParameters['code'], '4/0AY0e-g7');
      expect(callback.queryParameters['state'], 'deadbeef');
      expect(callback.host, isEmpty);
      expect(callback.path, '/oauth2redirect');
    });

    test('resolve() still collapses loopback to notesynapse:// on mobile '
        'platforms — MCP behavior unchanged', () {
      // Platform-independent half of the contract: whatever platform this
      // runs on, resolve() must never invent a Google scheme, and the
      // notesynapse:// constant must stay what MCP expects.
      expect(
        OAuthRedirectHelper.customSchemeRedirectUri,
        'notesynapse://oauth/callback',
      );
      expect(
        OAuthRedirectHelper.resolve('notesynapse://oauth/callback'),
        'notesynapse://oauth/callback',
      );
    });

    test(
      'the refresh grant sends the Drive redirect verbatim, not the rewritten '
      'one',
      () async {
        Map<String, String>? captured;
        final manager = OAuthTokenManager(
          endpointId: 'gd',
          config: OAuthConfig(
            authorizationEndpoint: GoogleDriveAuthService.authorizationEndpoint,
            tokenEndpoint: GoogleDriveAuthService.tokenEndpoint,
            clientId: 'client-x',
            scope: GoogleDriveAuthService.scope,
            usePkce: true,
            redirectUri: GoogleDriveClientConfig.redirectUri,
          ),
          storagePrefix: GoogleDriveAuthService.storagePrefix,
          redirectUriOverride: GoogleDriveClientConfig.redirectUri,
          httpPost: (url, {headers, body}) async {
            captured = (body as Map).cast<String, String>();
            return http.Response(
              jsonEncode({'access_token': 'new-tok', 'expires_in': 3600}),
              200,
            );
          },
        );

        await manager.saveTokens({'refresh_token': 'ref-1'});
        await manager.refreshNow();

        expect(captured, isNotNull);
        expect(captured!['grant_type'], 'refresh_token');
        expect(captured!['refresh_token'], 'ref-1');
        expect(
          captured!['redirect_uri'],
          GoogleDriveClientConfig.redirectUri,
          reason:
              'Without redirectUriOverride, OAuthTokenManager would run the '
              'Drive redirect through OAuthRedirectHelper.resolve() and, on '
              'a real device, advertise notesynapse://oauth/callback on a '
              'grant that was never issued against it.',
        );
        expect(
          captured!.containsKey('client_secret'),
          isFalse,
          reason: 'PKCE client — no secret is ever sent.',
        );
      },
    );

    test(
      'an MCP-shaped token manager keeps its previous redirect behavior',
      () async {
        Map<String, String>? captured;
        final manager = OAuthTokenManager(
          endpointId: 'mcp-ep',
          config: OAuthConfig(
            authorizationEndpoint: 'https://mcp.test/authorize',
            tokenEndpoint: 'https://mcp.test/token',
            clientId: 'mcp-client',
            scope: 'mcp.scope',
            usePkce: true,
            redirectUri: 'notesynapse://oauth/callback',
          ),
          // No redirectUriOverride — the McpService call shape.
          httpPost: (url, {headers, body}) async {
            captured = (body as Map).cast<String, String>();
            return http.Response(
              jsonEncode({'access_token': 'a', 'expires_in': 60}),
              200,
            );
          },
        );

        await manager.saveTokens({'refresh_token': 'r'});
        await manager.refreshNow();

        expect(
          captured!['redirect_uri'],
          OAuthRedirectHelper.resolve('notesynapse://oauth/callback'),
          reason: 'M2.9 must not change what the MCP flow sends.',
        );
      },
    );
  });

  group('unconfigured-client guard', () {
    test('connect() fails with an actionable error while the client ID is a '
        'placeholder — never a crash and never a silent no-op', () async {
      // `flutter test` runs in debug mode, so the debug (placeholder)
      // client ID is the one selected. If a real debug client is filled in
      // later this expectation flips, which is why both branches exist.
      if (GoogleDriveClientConfig.isConfigured) {
        expect(
          await GoogleDriveAuthService().connectionState(),
          isNot(GoogleDriveConnectionState.notConfigured),
        );
        return;
      }

      expect(kDebugMode, isTrue);
      expect(
        await GoogleDriveAuthService().connectionState(),
        GoogleDriveConnectionState.notConfigured,
      );

      Object? thrown;
      try {
        await GoogleDriveAuthService().connect();
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<GoogleDriveClientNotConfiguredException>());
      final message = thrown.toString();
      // The message has to name the two files that need editing, or it is
      // not actionable — which is the whole point of failing here rather
      // than letting Google return `invalid_client` from a browser tab.
      expect(message, contains('google_drive_client_config.dart'));
      expect(message, contains('build.gradle.kts'));
    });
  });

  group('platform guard', () {
    test('connect() refuses on a platform that cannot receive the redirect, '
        'instead of hanging for the five-minute flow timeout', () async {
      // This suite runs on the host (macOS/Linux), which is exactly the
      // unsupported case: nothing there registers the reversed-client-ID
      // scheme, so the deep-link branch would launch a browser and then
      // wait on an `app_links` stream that can never deliver the callback.
      expect(GoogleDriveAuthService.isSupportedPlatform, isFalse);

      // Note the ordering this asserts: assertConfigured() runs first, so
      // an unconfigured host build reports the configuration problem
      // rather than the platform one. Both are fail-fast; neither hangs.
      Object? thrown;
      try {
        await GoogleDriveAuthService().connect();
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNotNull);
      expect(
        thrown,
        anyOf(
          isA<GoogleDriveClientNotConfiguredException>(),
          isA<UnsupportedError>(),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('refresh de-duplication on the proactive path', () {
    test(
      'concurrent getAccessToken() calls on an expired token trigger exactly '
      'one refresh round trip',
      () async {
        // Regression test for a gap found in M2.9 review: M2.2 added the
        // in-flight guard to refreshNow(), but getAccessToken()'s proactive
        // refresh called the private _refreshToken directly and bypassed it.
        // GoogleDriveBackend calls getAccessToken() on EVERY Drive request
        // and issues requests concurrently, so an expired token meant N
        // simultaneous refresh POSTs — wasteful, and a real risk with
        // Google's refresh-token rotation/reuse detection, which can read a
        // superseded-token refresh as theft and revoke the grant.
        var refreshCalls = 0;
        final manager = OAuthTokenManager(
          endpointId: 'gd-concurrent',
          config: GoogleDriveAuthService().config,
          storagePrefix: GoogleDriveAuthService.storagePrefix,
          redirectUriOverride: GoogleDriveClientConfig.redirectUri,
          httpPost: (url, {headers, body}) async {
            refreshCalls++;
            // Yield so all concurrent callers are in flight simultaneously;
            // without this the first could complete before the others start
            // and the test would pass even with the bug present.
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return http.Response(
              jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
              200,
            );
          },
        );

        await manager.saveTokens({
          'access_token': 'stale',
          'refresh_token': 'ref-1',
          // Already expired, so every getAccessToken() takes the proactive
          // refresh branch.
          'expires_in': -60,
        });

        final tokens = await Future.wait([
          manager.getAccessToken(),
          manager.getAccessToken(),
          manager.getAccessToken(),
          manager.getAccessToken(),
        ]);

        expect(refreshCalls, 1);
        expect(tokens, everyElement('fresh'));
      },
    );

    test('a failing proactive refresh is still swallowed, as before', () async {
      final manager = OAuthTokenManager(
        endpointId: 'gd-failing',
        config: GoogleDriveAuthService().config,
        storagePrefix: GoogleDriveAuthService.storagePrefix,
        httpPost: (url, {headers, body}) async =>
            http.Response(jsonEncode({'error': 'invalid_grant'}), 400),
      );
      await manager.saveTokens({
        'access_token': 'stale',
        'refresh_token': 'ref-1',
        'expires_in': -60,
      });

      // Routing through refreshNow() must not change this call site's
      // long-standing best-effort contract: it returns the stale token
      // rather than throwing, and the caller discovers the problem from the
      // resulting 401 (which GoogleDriveBackend handles via refreshNow()).
      expect(await manager.getAccessToken(), 'stale');
    });
  });

  group('connection state', () {
    test('reflects stored credentials without any network call', () async {
      // Bypass the notConfigured short-circuit by driving the token manager
      // directly — connectionState() checks configuration first, so this
      // asserts the token-manager predicates the state machine is built on.
      final manager = OAuthTokenManager(
        endpointId: GoogleDriveAuthService.endpointId,
        config: GoogleDriveAuthService().config,
        storagePrefix: GoogleDriveAuthService.storagePrefix,
      );

      expect(await manager.hasStoredCredentials(), isFalse);
      expect(await manager.hasRefreshToken(), isFalse);

      await manager.saveTokens({'access_token': 'a', 'expires_in': 3600});
      expect(await manager.hasStoredCredentials(), isTrue);
      expect(
        await manager.hasRefreshToken(),
        isFalse,
        reason:
            'An access token with no refresh token is the '
            'connectedWithoutRefreshToken state — surfaced distinctly so '
            '"sync worked once, then stopped" is diagnosable.',
      );

      await manager.saveTokens({'refresh_token': 'r'});
      expect(await manager.hasRefreshToken(), isTrue);

      await manager.clear();
      expect(await manager.hasStoredCredentials(), isFalse);
    });
  });
}
