// M2.2: runs the M2.1 conformance suite (`runSyncBackendConformanceSuite`,
// written once against the abstract `SyncBackend` interface — § 8.6)
// against `GoogleDriveBackend` UNMODIFIED, wired to `FakeDriveHttpTransport`
// instead of a real network. This is what makes `GoogleDriveBackend`'s own
// translation logic (Drive API calls <-> `SyncBackend` semantics) the thing
// actually under test, not a re-test of the interface's own contract (that
// was already proven once, against `MockSyncBackend`, in M2.1).
//
// Also covers the Drive-specific scenarios the abstract suite structurally
// cannot: the §8.4 existence-check-before-create duplicate-create race
// (with a real, non-atomic multi-round-trip create — GoogleDriveBackend has
// no `simulateNonAtomicCreate` flag the way `MockSyncBackend` does, because
// every one of its writes is *already* non-atomic by construction), `
// CommitPage.hasGap` under simulated Drive listing eventual consistency
// (§8.2 item 6), and the 401-triggers-forced-refresh-then-retry flow
// (§8.3), including the revoked-refresh-token variant.
//
// **What this file proves, and what it doesn't — see the doc comments atop
// `google_drive_backend.dart` and `fake_drive_http_transport.dart` for the
// full statement.** In short: this validates `GoogleDriveBackend` against a
// hand-written model of Drive's REST API v3 surface, not the real API. The
// § 8.6-required real-Google-endpoints manual smoke test has not been
// performed and cannot be automated in this environment.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';
import 'package:note_synapse/services/sync/google_drive_backend.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/sync_backend_exceptions.dart';

import 'conformance_suite.dart';
import 'fake_drive_http_transport.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

OAuthConfig _testOAuthConfig() => OAuthConfig(
  authorizationEndpoint: 'https://accounts.google.test/o/oauth2/auth',
  tokenEndpoint: 'https://oauth2.google.test/token',
  clientId: 'test-client-id',
  scope: 'https://www.googleapis.com/auth/drive.file',
  usePkce: true,
  redirectUri: 'notesynapse://oauth/callback',
);

/// Backend wired to [transport] with a pre-seeded, never-expiring access
/// token (via the file-level `setUp` below, which seeds
/// `gdrive_oauth_test_token_drive-test`) — for every test that isn't
/// itself specifically about the auth/refresh flow.
GoogleDriveBackend _backendWithTransport(
  FakeDriveHttpTransport transport, {
  String endpointId = 'drive-test',
}) {
  final tokenManager = OAuthTokenManager(
    endpointId: endpointId,
    config: _testOAuthConfig(),
    storagePrefix: 'gdrive_oauth_test_',
  );
  return GoogleDriveBackend(tokenManager: tokenManager, httpClient: transport);
}

GoogleDriveBackend _createConformanceBackend() =>
    _backendWithTransport(FakeDriveHttpTransport());

Future<String> _appendOk(
  SyncBackend backend, {
  required String deviceLogId,
  required int deviceSeq,
  required String publishIntentId,
  required String? parentCommitHash,
  required String payload,
}) async {
  final outcome = await backend.appendCommit(
    deviceLogId: deviceLogId,
    deviceSeq: deviceSeq,
    publishIntentId: publishIntentId,
    parentCommitHash: parentCommitHash,
    commitBytes: _bytes(payload),
  );
  expect(outcome, isA<AppendCommitSucceeded>());
  return (outcome as AppendCommitSucceeded).commitHash;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'gdrive_oauth_test_token_drive-test': 'test-access-token',
    });
  });

  // ===========================================================================
  // The M2.1 conformance suite, unmodified, against GoogleDriveBackend +
  // FakeDriveHttpTransport.
  // ===========================================================================
  runSyncBackendConformanceSuite(
    _createConformanceBackend,
    suiteLabel: 'SyncBackend conformance (GoogleDriveBackend + FakeDriveHttpTransport)',
  );

  // ===========================================================================
  // Drive-specific scenarios the abstract suite can't express.
  // ===========================================================================
  group('GoogleDriveBackend-specific (§ 8.4 / § 8.6)', () {
    test(
      'the §8.4 duplicate-create race: two concurrent appendCommit calls under the '
      'identical publishIntentId can both pass the existence check before either '
      'creates — producing two distinct stored Drive objects at the same '
      '(deviceLogId, deviceSeq) slot — but every ordinary caller-facing read still '
      'converges on exactly one commit',
      () async {
        final transport = FakeDriveHttpTransport();
        final backend = _backendWithTransport(transport);
        // Resolve the root folder outside the race so this test is scoped to
        // the commit-level existence-check-before-create gap specifically,
        // not conflated with the identically-shaped (but separate) root-
        // folder creation race.
        await backend.listDeviceLogIds();

        final results = await Future.wait([
          backend.appendCommit(
            deviceLogId: 'device-1',
            deviceSeq: 1,
            publishIntentId: 'racing-intent',
            parentCommitHash: null,
            commitBytes: _bytes('op-1'),
          ),
          backend.appendCommit(
            deviceLogId: 'device-1',
            deviceSeq: 1,
            publishIntentId: 'racing-intent',
            parentCommitHash: null,
            commitBytes: _bytes('op-1'),
          ),
        ]);

        // From the caller's own perspective, both calls look successful —
        // exactly what §8.4 discloses: the race isn't caught by the caller,
        // and (since commitHash is deterministic from its inputs) both
        // report the identical hash.
        expect(results, everyElement(isA<AppendCommitSucceeded>()));
        final hashes = results
            .cast<AppendCommitSucceeded>()
            .map((r) => r.commitHash)
            .toSet();
        expect(hashes, hasLength(1));

        // The storage-layer anomaly the mitigation does NOT eliminate: two
        // distinct Drive objects at the identical slot.
        final storedCount = transport.debugCountMatching({
          'deviceLogId': 'device-1',
          'deviceSeq': '1',
        });
        expect(
          storedCount,
          2,
          reason:
              'expected the race to produce two stored objects at the same slot — '
              'this is §8.4\'s disclosed, not eliminated, residual risk',
        );

        // But every ordinary read still converges on exactly one commit.
        final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
        expect(page.commits, hasLength(1));

        // A THIRD, sequential (non-racing) retry under the same intent must
        // still be a clean no-op — the mitigation's ordinary-case guarantee,
        // unaffected by the race having already happened once.
        final retry = await backend.appendCommit(
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'racing-intent',
          parentCommitHash: null,
          commitBytes: _bytes('op-1'),
        );
        expect(retry, isA<AppendCommitSucceeded>());
        expect(
          transport.debugCountMatching({'deviceLogId': 'device-1', 'deviceSeq': '1'}),
          2,
          reason: 'a subsequent non-racing retry must not add a THIRD stored object',
        );
      },
    );

    test(
      'CommitPage.hasGap under simulated Drive listing eventual consistency (§ 8.2 item 6)',
      () async {
        final transport = FakeDriveHttpTransport();
        final backend = _backendWithTransport(transport);

        final h1 = await _appendOk(
          backend,
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'i1',
          parentCommitHash: null,
          payload: 'op-1',
        );
        final h2 = await _appendOk(
          backend,
          deviceLogId: 'device-1',
          deviceSeq: 2,
          publishIntentId: 'i2',
          parentCommitHash: h1,
          payload: 'op-2',
        );
        await _appendOk(
          backend,
          deviceLogId: 'device-1',
          deviceSeq: 3,
          publishIntentId: 'i3',
          parentCommitHash: h2,
          payload: 'op-3',
        );

        // Simulate seq-2's object durably written but not yet visible in
        // Drive's own listing index — not a write-path bug, Drive's own
        // documented eventual consistency.
        transport.debugHideNewestMatchingFromListings(
          {'deviceLogId': 'device-1', 'deviceSeq': '2'},
          forListCalls: 10,
        );

        final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
        expect(
          page.hasGap,
          isTrue,
          reason: 'a non-contiguous listing must be surfaced as hasGap, never silently '
              'skipped past (§ Architecture 2/3 no-gap-skipping)',
        );
        expect(page.commits.map((c) => c.deviceSeq), [1, 3]);
      },
    );

    test(
      '401 triggers a forced refresh via OAuthTokenManager.refreshNow(), then a single '
      'retry (§ 8.3) — success case',
      () async {
        final transport = FakeDriveHttpTransport();
        var refreshCalls = 0;
        final tokenManager = OAuthTokenManager(
          endpointId: 'drive-401-success',
          config: _testOAuthConfig(),
          storagePrefix: 'gdrive_oauth_401_success_',
          httpPost: (url, {headers, body}) async {
            refreshCalls++;
            return http.Response(
              jsonEncode({'access_token': 'new-token', 'expires_in': 3600}),
              200,
            );
          },
        );
        await tokenManager.saveTokens({
          'access_token': 'old-token',
          'refresh_token': 'refresh-1',
          // No expires_in saved: getAccessToken()'s own proactive-refresh
          // check never fires (no expiry recorded). The only way
          // `httpPost` gets called in this test is via
          // GoogleDriveBackend's own 401 handling below.
        });

        transport.scriptedFailures.add(
          ScriptedDriveFailure.unauthorized(staleBearerToken: 'old-token'),
        );

        final backend = GoogleDriveBackend(tokenManager: tokenManager, httpClient: transport);
        final ids = await backend.listDeviceLogIds();

        expect(ids, isEmpty);
        expect(refreshCalls, 1, reason: 'exactly one forced refresh, not a retry loop');
        expect(await tokenManager.getAccessToken(), 'new-token');
      },
    );

    test(
      '401 followed by a revoked refresh token (invalid_grant) surfaces '
      'SyncRefreshTokenRevokedException, distinct from a transient auth failure, '
      'never retried silently',
      () async {
        final transport = FakeDriveHttpTransport();
        final tokenManager = OAuthTokenManager(
          endpointId: 'drive-401-revoked',
          config: _testOAuthConfig(),
          storagePrefix: 'gdrive_oauth_401_revoked_',
          httpPost: (url, {headers, body}) async => http.Response(
            jsonEncode({'error': 'invalid_grant', 'error_description': 'revoked'}),
            400,
          ),
        );
        await tokenManager.saveTokens({
          'access_token': 'old-token',
          'refresh_token': 'refresh-1',
        });
        transport.scriptedFailures.add(
          ScriptedDriveFailure.unauthorized(staleBearerToken: 'old-token'),
        );

        final backend = GoogleDriveBackend(tokenManager: tokenManager, httpClient: transport);
        await expectLater(
          backend.listDeviceLogIds(),
          throwsA(isA<SyncRefreshTokenRevokedException>()),
        );
      },
    );

    test('403 with a rate-limit reason maps to SyncRateLimitedException with retryAfter',
        () async {
      final transport = FakeDriveHttpTransport();
      transport.scriptedFailures.add(
        ScriptedDriveFailure.rateLimited(retryAfterSeconds: 5),
      );
      final backend = _backendWithTransport(transport);

      await expectLater(
        backend.listDeviceLogIds(),
        throwsA(
          isA<SyncRateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 5),
          ),
        ),
      );
    });

    test('403 with a storage-quota reason maps to SyncQuotaExceededException', () async {
      final transport = FakeDriveHttpTransport();
      transport.scriptedFailures.add(ScriptedDriveFailure.quotaExceeded());
      final backend = _backendWithTransport(transport);

      await expectLater(
        backend.listDeviceLogIds(),
        throwsA(isA<SyncQuotaExceededException>()),
      );
    });

    test('a 5xx maps to SyncNetworkException, not a raw/unmapped error', () async {
      final transport = FakeDriveHttpTransport();
      transport.scriptedFailures.add(ScriptedDriveFailure.serverError(statusCode: 503));
      final backend = _backendWithTransport(transport);

      await expectLater(
        backend.listDeviceLogIds(),
        throwsA(isA<SyncNetworkException>()),
      );
    });

    test(
      'deleteConditionally rejects IfUnmodifiedSince outright — Drive has no conditional-'
      'delete primitive (capabilities.supportsConditionalDelete == false)',
      () async {
        final backend = _backendWithTransport(FakeDriveHttpTransport());
        expect(backend.capabilities.supportsConditionalDelete, isFalse);
        expect(
          () => backend.deleteConditionally(
            ref: const BlobRef('does-not-matter'),
            precondition: const IfUnmodifiedSince('some-token'),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('capabilities.supportsPersistentExternalFolder is false for Drive', () async {
      final backend = _backendWithTransport(FakeDriveHttpTransport());
      expect(backend.capabilities.supportsPersistentExternalFolder, isFalse);
    });

    test(
      'uploadBlob cross-checks Drive\'s reported md5Checksum against a locally '
      'computed md5 of the exact bytes sent, catching a torn/corrupted write the '
      'declared-contentHash pre-check cannot see (§ 8.2 item 2)',
      () async {
        final transport = FakeDriveHttpTransport();
        final backend = _backendWithTransport(transport);
        final bytes = _bytes('attachment payload for corruption test');
        final hash = _sha256Hex(bytes);

        // Deliberately corrupt the transport's post-write md5 report for the
        // very next created object — models a torn write / storage-layer
        // corruption between "bytes we sent" and "bytes Drive says it has",
        // independent of anything the declared-contentHash pre-check
        // (computed from the same bytes before any network call) could
        // ever catch.
        transport.corruptNextUploadMd5 = true;

        await expectLater(
          backend.uploadBlob(
            contentHash: hash,
            data: Stream.value(bytes),
            length: bytes.length,
          ),
          throwsA(isA<SyncHashMismatchException>()),
        );
        expect(
          await backend.blobExists(hash),
          isFalse,
          reason: 'a detected torn write must not leave a stored (corrupt, mislabeled) '
              'blob behind — best-effort cleanup deletes it',
        );
      },
    );

    test(
      'uploadBlob falls back to re-download-and-rehash when Drive\'s create response '
      'omits md5Checksum entirely — an absent field must never be silently treated as '
      '"verified" (review finding: this path previously had zero test coverage since '
      'the fake always populated the field)',
      () async {
        final transport = FakeDriveHttpTransport();
        final backend = _backendWithTransport(transport);
        final bytes = _bytes('payload uploaded with no md5Checksum in the response');
        final hash = _sha256Hex(bytes);

        transport.omitMd5ChecksumForNextUpload = true;

        // The content itself is NOT corrupted here — only the response
        // field is missing — so the fallback verification (re-download +
        // rehash against the declared contentHash) must succeed and the
        // upload must be accepted.
        await backend.uploadBlob(
          contentHash: hash,
          data: Stream.value(bytes),
          length: bytes.length,
        );
        expect(await backend.blobExists(hash), isTrue);
        final downloaded = await (await backend.downloadBlob(hash)).toList();
        expect(downloaded.expand((c) => c).toList(), bytes);
      },
    );

    test(
      'uploadBlob still catches a torn write via the fallback path when '
      'md5Checksum is BOTH omitted AND the underlying bytes are corrupted — '
      'the fallback path is a genuine independent check, not a silent pass',
      () async {
        final transport = FakeDriveHttpTransport();
        final backend = _backendWithTransport(transport);
        final bytes = _bytes('payload that will be corrupted with no md5Checksum reported');
        final hash = _sha256Hex(bytes);

        transport.omitMd5ChecksumForNextUpload = true;
        transport.corruptNextUploadMd5 = true;

        await expectLater(
          backend.uploadBlob(
            contentHash: hash,
            data: Stream.value(bytes),
            length: bytes.length,
          ),
          throwsA(isA<SyncHashMismatchException>()),
        );
        expect(
          await backend.blobExists(hash),
          isFalse,
          reason: 'a torn write caught via the fallback path must still be cleaned up',
        );
      },
    );
  });
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
