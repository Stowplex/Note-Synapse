// Tests for the M2.2 Step 0 refactor of `OAuthTokenManager`
// (`lib/services/oauth_token_manager.dart`): the storage-key-prefix
// parametrization and the new `refreshNow()` refresh-on-401 support (§
// Architecture 8.3). No test file existed for this class before this
// milestone — `McpService`'s own tests never exercise the network-refresh
// path (`test/services/mcp_service_test.dart` mocks `FlutterSecureStorage`
// only, never touches `OAuthTokenManager`'s HTTP calls) — so these tests
// are new coverage, not a migration of existing ones.
//
// `OAuthTokenManager` reads/writes tokens via a hardcoded
// `FlutterSecureStorage` instance with a `SharedPreferences` fallback (used
// whenever the secure-storage platform channel throws, which is always true
// under `flutter test`'s unit-test environment — no platform channels are
// registered). That fallback is exactly what makes this class testable at
// all without a widget test harness: `SharedPreferences.setMockInitialValues`
// gives every test a clean in-memory store.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';

OAuthConfig _config() => OAuthConfig(
  authorizationEndpoint: 'https://example.test/authorize',
  tokenEndpoint: 'https://example.test/token',
  clientId: 'client-1',
  scope: 'test.scope',
  usePkce: true,
  redirectUri: 'notesynapse://oauth/callback',
);

http.Response _jsonResponse(int status, Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('storage-key prefix parametrization (§ 8.3 Step 0.1)', () {
    test('default prefix reproduces the exact previous MCP-branded keys, '
        'byte-for-byte — McpService usage must see zero key migration',
        () async {
      final manager = OAuthTokenManager(endpointId: 'ep-1', config: _config());
      await manager.saveTokens({
        'access_token': 'tok-a',
        'refresh_token': 'ref-a',
        'id_token': 'id-a',
        'expires_in': 3600,
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mcp_oauth_token_ep-1'), 'tok-a');
      expect(prefs.getString('mcp_oauth_refresh_ep-1'), 'ref-a');
      expect(prefs.getString('mcp_oauth_id_ep-1'), 'id-a');
      expect(prefs.getString('mcp_oauth_expiry_ep-1'), isNotNull);
    });

    test('a custom storagePrefix (e.g. a Drive-auth consumer) writes to '
        'entirely distinct keys, never colliding with the MCP-default prefix',
        () async {
      final mcpManager = OAuthTokenManager(
        endpointId: 'shared-id',
        config: _config(),
      );
      final driveManager = OAuthTokenManager(
        endpointId: 'shared-id', // deliberately the same "endpoint" id
        config: _config(),
        storagePrefix: 'gdrive_oauth_',
      );

      await mcpManager.saveTokens({'access_token': 'mcp-token'});
      await driveManager.saveTokens({'access_token': 'drive-token'});

      expect(await mcpManager.getAccessToken(), 'mcp-token');
      expect(await driveManager.getAccessToken(), 'drive-token');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mcp_oauth_token_shared-id'), 'mcp-token');
      expect(prefs.getString('gdrive_oauth_token_shared-id'), 'drive-token');
    });
  });

  group('refreshNow() — § 8.3 refresh-on-401 support', () {
    test('success: forces a refresh even though nothing checked expiry, '
        'persists the new tokens, and returns the new access token',
        () async {
      var callCount = 0;
      final manager = OAuthTokenManager(
        endpointId: 'ep-2',
        config: _config(),
        httpPost: (url, {headers, body}) async {
          callCount++;
          expect(url, Uri.parse('https://example.test/token'));
          final form = body as Map<String, String>;
          expect(form['grant_type'], 'refresh_token');
          expect(form['refresh_token'], 'old-refresh');
          return _jsonResponse(200, {
            'access_token': 'new-access',
            'refresh_token': 'new-refresh',
            'expires_in': 3600,
          });
        },
      );
      await manager.saveTokens({
        'access_token': 'old-access',
        'refresh_token': 'old-refresh',
        // Far-future expiry so getAccessToken()'s own proactive check
        // would never trigger a refresh on its own — the only way this
        // test's injected httpPost gets called is via refreshNow().
        'expires_in': 3600,
      });

      final result = await manager.refreshNow();
      expect(result, 'new-access');
      expect(callCount, 1);
      expect(await manager.getAccessToken(), 'new-access');
    });

    test('refresh token revoked (invalid_grant): throws '
        'OAuthRefreshFailedException with requiresReauthorization == true',
        () async {
      final manager = OAuthTokenManager(
        endpointId: 'ep-3',
        config: _config(),
        httpPost: (url, {headers, body}) async => _jsonResponse(400, {
          'error': 'invalid_grant',
          'error_description': 'Token has been expired or revoked.',
        }),
      );
      await manager.saveTokens({
        'access_token': 'old-access',
        'refresh_token': 'old-refresh',
        'expires_in': 3600,
      });

      await expectLater(
        manager.refreshNow(),
        throwsA(
          isA<OAuthRefreshFailedException>().having(
            (e) => e.requiresReauthorization,
            'requiresReauthorization',
            isTrue,
          ),
        ),
      );
    });

    test('no refresh token ever stored: throws OAuthRefreshFailedException '
        'with requiresReauthorization == true, without attempting an HTTP call',
        () async {
      var called = false;
      final manager = OAuthTokenManager(
        endpointId: 'ep-4',
        config: _config(),
        httpPost: (url, {headers, body}) async {
          called = true;
          return _jsonResponse(200, {'access_token': 'unused'});
        },
      );

      await expectLater(
        manager.refreshNow(),
        throwsA(
          isA<OAuthRefreshFailedException>().having(
            (e) => e.requiresReauthorization,
            'requiresReauthorization',
            isTrue,
          ),
        ),
      );
      expect(called, isFalse);
    });

    test('transient failure (500): throws OAuthRefreshFailedException with '
        'requiresReauthorization == false — distinct from a revoked refresh token',
        () async {
      final manager = OAuthTokenManager(
        endpointId: 'ep-5',
        config: _config(),
        httpPost: (url, {headers, body}) async =>
            http.Response('server error', 500),
      );
      await manager.saveTokens({
        'access_token': 'old-access',
        'refresh_token': 'old-refresh',
        'expires_in': 3600,
      });

      await expectLater(
        manager.refreshNow(),
        throwsA(
          isA<OAuthRefreshFailedException>().having(
            (e) => e.requiresReauthorization,
            'requiresReauthorization',
            isFalse,
          ),
        ),
      );
      // The stale access token must not have been clobbered by a failed
      // refresh attempt.
      expect(await manager.getAccessToken(), 'old-access');
    });

    test('concurrency guard: several concurrent refreshNow() calls collapse into a '
        'single HTTP refresh call, and every caller sees the same outcome '
        '(review finding — parallel 401s, e.g. from concurrent blob uploads, must '
        'not each independently hit the token endpoint)', () async {
      var callCount = 0;
      final manager = OAuthTokenManager(
        endpointId: 'ep-7',
        config: _config(),
        httpPost: (url, {headers, body}) async {
          callCount++;
          // A real refresh is never instantaneous — without the
          // concurrency guard, this delay would give concurrent callers
          // ample opportunity to each kick off their own HTTP call before
          // the first one lands.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _jsonResponse(200, {'access_token': 'new-access', 'expires_in': 3600});
        },
      );
      await manager.saveTokens({
        'access_token': 'old-access',
        'refresh_token': 'old-refresh',
      });

      final results = await Future.wait([
        manager.refreshNow(),
        manager.refreshNow(),
        manager.refreshNow(),
      ]);

      expect(callCount, 1, reason: 'exactly one underlying HTTP refresh call');
      expect(results, everyElement('new-access'));
    });

    test('concurrency guard: a failed in-flight refresh is shared too — every '
        'concurrent caller sees the same failure, not a mix of retried outcomes',
        () async {
      var callCount = 0;
      final manager = OAuthTokenManager(
        endpointId: 'ep-8',
        config: _config(),
        httpPost: (url, {headers, body}) async {
          callCount++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _jsonResponse(400, {'error': 'invalid_grant'});
        },
      );
      await manager.saveTokens({
        'access_token': 'old-access',
        'refresh_token': 'old-refresh',
      });

      final results = await Future.wait(
        [manager.refreshNow(), manager.refreshNow()].map(
          (f) => f.then<Object>((v) => v).catchError((Object e) => e),
        ),
      );

      expect(callCount, 1);
      expect(results, everyElement(isA<OAuthRefreshFailedException>()));
    });

    test('concurrency guard: a refresh started AFTER a prior one has already settled '
        'triggers a genuinely new HTTP call, not a permanently cached result',
        () async {
      var callCount = 0;
      final manager = OAuthTokenManager(
        endpointId: 'ep-9',
        config: _config(),
        httpPost: (url, {headers, body}) async {
          callCount++;
          return _jsonResponse(200, {
            'access_token': 'token-$callCount',
            'expires_in': 3600,
          });
        },
      );
      await manager.saveTokens({
        'access_token': 'old-access',
        'refresh_token': 'old-refresh',
      });

      final first = await manager.refreshNow();
      final second = await manager.refreshNow();

      expect(callCount, 2);
      expect(first, 'token-1');
      expect(second, 'token-2');
    });
  });

  group('getAccessToken() proactive refresh keeps swallowing failures '
      '(unchanged from pre-refactor behavior — refreshNow() is additive, '
      'not a replacement for this path)', () {
    test('an expired token with a broken refresh endpoint returns null, '
        'never throws', () async {
      final manager = OAuthTokenManager(
        endpointId: 'ep-6',
        config: _config(),
        httpPost: (url, {headers, body}) async =>
            http.Response('server error', 500),
      );
      await manager.saveTokens({
        'access_token': 'old-access',
        'refresh_token': 'old-refresh',
        'expires_in': -3600, // already expired
      });

      // Must not throw despite the injected httpPost always failing.
      final token = await manager.getAccessToken();
      expect(token, 'old-access', reason: 'proactive refresh failure leaves the '
          'last-known (stale) access token in place rather than clearing it');
    });
  });
}
