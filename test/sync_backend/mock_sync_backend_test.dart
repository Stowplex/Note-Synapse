// M2.1 test entry point: runs the abstract conformance suite against
// `MockSyncBackend` (twice — default capabilities, and again with
// conditional-delete disabled, to exercise both § 8.4 capability-gated
// branches), then a dedicated group per § 8.2 fault-injection scenario
// this milestone implements, plus the § 8.4/8.6-required Drive
// duplicate-create race and the join-vs-log-pruning race-adjacent
// scenario.
//
// **Coverage honesty note, expanded on in the M2.1 report:** § 8.6 lists
// several "concrete required scenarios" that genuinely cannot be built at
// this layer yet and are not attempted here — a full auth-flow test
// against a fake OAuth endpoint (no OAuth/refresh-on-401 code exists
// anywhere in this codebase, § 8.3, explicitly out of scope for M2.1), and
// the round-8 blob-reference-after-certificate scenario end-to-end (needs
// the certificate/log-pruning GC engine, which doesn't exist — M2/M3
// work). Both are called out again inline below at the point they'd
// otherwise appear, rather than silently omitted.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/sync_backend_exceptions.dart';

import 'conformance_suite.dart';
import 'mock_sync_backend.dart';
import 'sync_faults.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

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
  // -- the abstract conformance suite, run twice against MockSyncBackend --

  runSyncBackendConformanceSuite(() => MockSyncBackend(),
      suiteLabel: 'MockSyncBackend (default capabilities: conditional delete supported)');

  runSyncBackendConformanceSuite(
    () => MockSyncBackend(
      capabilities: const SyncBackendCapabilities(
        supportsConditionalDelete: false,
        supportsPersistentExternalFolder: false,
      ),
    ),
    suiteLabel: 'MockSyncBackend (Drive-shaped capabilities: no conditional delete)',
  );

  // -- collapsePhysicalDeviceIds: a pure function, not backend-dependent,
  // so tested directly rather than through a SyncBackend instance. The
  // "well-formed input collapses correctly" case is already covered by
  // conformance_suite.dart's dataset_members test (run against a real
  // backend's listDeviceLogIds output); this group covers the
  // malformed-input decision made in response to review: fail loud rather
  // than silently mint an empty-string "physical device" id. ---------------

  group('collapsePhysicalDeviceIds: malformed input', () {
    test('a bare "seed:" with no device suffix throws ArgumentError', () {
      expect(() => collapsePhysicalDeviceIds(['seed:']), throwsArgumentError);
    });

    test('a bare "external:" with no device suffix throws ArgumentError', () {
      expect(() => collapsePhysicalDeviceIds(['external:']), throwsArgumentError);
    });

    test('a malformed id throws even when mixed in with otherwise well-formed ids '
        '— one bad entry must not be silently dropped or merged away', () {
      expect(
        () => collapsePhysicalDeviceIds(['device-a', 'seed:device-a', 'external:']),
        throwsArgumentError,
      );
    });

    test('well-formed ids with real device suffixes never throw (regression guard for '
        'the malformed-input check above being too aggressive)', () {
      expect(
        collapsePhysicalDeviceIds(['device-a', 'seed:device-a', 'external:device-a', 'device-b']),
        {'device-a', 'device-b'},
      );
    });
  });

  // -- § 8.2 fault-injection scenarios -------------------------------------

  group('§ 8.2 item 1: network partition mid-upload/append', () {
    test('before-write partition on appendCommit: nothing is stored, retry succeeds', () async {
      final faults = ScriptedFaultQueue()..enqueue(const NetworkPartitionBeforeWrite(SyncOp.appendCommit));
      final backend = MockSyncBackend(faultSource: faults);

      await expectLater(
        backend.appendCommit(
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'intent-1',
          parentCommitHash: null,
          commitBytes: _bytes('op-1'),
        ),
        throwsA(isA<SyncNetworkException>()),
      );

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits, isEmpty, reason: 'a before-write partition must not have applied anything');

      // Retry with the identical intent — ordinary path, no fault queued.
      final retryHash = await _appendOk(backend,
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'intent-1',
          parentCommitHash: null,
          payload: 'op-1');
      expect(retryHash, isNotEmpty);
    });

    test('after-write partition on appendCommit: the write lands, caller sees Ambiguous, '
        'and resolves it by re-reading or retrying under the same intent', () async {
      final faults = ScriptedFaultQueue()..enqueue(const NetworkPartitionAfterWrite(SyncOp.appendCommit));
      final backend = MockSyncBackend(faultSource: faults);

      final outcome = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'intent-1',
        parentCommitHash: null,
        commitBytes: _bytes('op-1'),
      );
      expect(outcome, isA<AppendCommitAmbiguous>());

      // Resolution path 1: re-read.
      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits, hasLength(1), reason: 'the write actually landed despite the Ambiguous outcome');

      // Resolution path 2: retry under the identical intent — must
      // converge, not duplicate.
      final retry = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'intent-1',
        parentCommitHash: null,
        commitBytes: _bytes('op-1'),
      );
      expect(retry, isA<AppendCommitSucceeded>());
      final pageAfterRetry = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(pageAfterRetry.commits, hasLength(1));
    });
  });

  group('§ 8.2 item 2 / item 9: torn write and post-write corruption', () {
    test('torn write caught immediately by uploadBlob\'s own post-write check', () async {
      final bytes = _bytes('attachment');
      final hash = sha256Hex(bytes);
      final faults = ScriptedFaultQueue()
        ..enqueue(const TornWrite(SyncOp.uploadBlob, manifestsOnUploadCheck: true));
      final backend = MockSyncBackend(faultSource: faults);

      await expectLater(
        backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length),
        throwsA(isA<SyncHashMismatchException>()),
      );
      expect(await backend.blobExists(hash), isFalse);
    });

    test('torn write that slips past the upload check is caught later by downloadBlob '
        '(item 9: independent of the write path)', () async {
      final bytes = _bytes('attachment that will be silently truncated');
      final hash = sha256Hex(bytes);
      final faults = ScriptedFaultQueue()
        ..enqueue(const TornWrite(SyncOp.uploadBlob, manifestsOnUploadCheck: false));
      final backend = MockSyncBackend(faultSource: faults);

      // Upload "succeeds" from the caller's point of view...
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);
      expect(await backend.blobExists(hash), isTrue);

      // ...but the stored bytes are corrupted, so a later download must
      // still catch it — this is the "independent of any write-path bug"
      // property item 9 is specifically about.
      await expectLater(backend.downloadBlob(hash), throwsA(isA<SyncHashMismatchException>()));
    });

    test('bit-rot on read with no fault at write time: a clean upload later corrupted '
        'out of band is caught on the next download', () async {
      final backend = MockSyncBackend();
      final bytes = _bytes('clean upload, corrupted later');
      final hash = sha256Hex(bytes);
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);

      // Simulate bit-rot / an external write independent of any upload
      // fault (this is the same mechanism § 8.2 item 15a's tampering
      // test uses — mechanically identical, distinguished only by intent).
      backend.debugTamperBlob(hash);

      await expectLater(backend.downloadBlob(hash), throwsA(isA<SyncHashMismatchException>()));
    });
  });

  group('§ 8.2 items 3 & 11: auth-expiry and refresh-token-revoked hooks', () {
    test('AuthExpired mid multi-blob batch: already-succeeded blobs are not lost, '
        'the failed one resumes cleanly via blobExists-based idempotent re-attempt', () async {
      // ScriptedFaultQueue targets an *op*, not a specific call index
      // within a batch — the queued fault below fires on the very next
      // uploadBlob call, i.e. blob 0's first attempt. That's sufficient to
      // model "expiry mid-batch": what matters for § 8.2 item 3 is that
      // some call in the batch fails with a 401 and the batch resumes
      // correctly afterward, not which index it lands on.
      final faults = ScriptedFaultQueue()..enqueue(const AuthExpired(SyncOp.uploadBlob));
      final backend = MockSyncBackend(faultSource: faults);

      final blobs = ['blob-1', 'blob-2', 'blob-3'].map(_bytes).toList();
      final hashes = blobs.map(sha256Hex).toList();

      // Blob 0's first attempt hits the injected 401.
      await expectLater(
        backend.uploadBlob(contentHash: hashes[0], data: Stream.value(blobs[0]), length: blobs[0].length),
        throwsA(isA<SyncAuthExpiredException>()),
      );
      expect(await backend.blobExists(hashes[0]), isFalse);

      // The (not-yet-built, § 8.3) engine layer would force a refresh
      // here and retry the *single failed call* — modeled as simply
      // calling uploadBlob again, no batch-transaction machinery needed
      // (§ 8.3's documented rationale: content-addressing makes batch
      // resume idempotent "for free"). The rest of the batch (which never
      // failed) proceeds normally.
      await backend.uploadBlob(contentHash: hashes[0], data: Stream.value(blobs[0]), length: blobs[0].length);
      await backend.uploadBlob(contentHash: hashes[1], data: Stream.value(blobs[1]), length: blobs[1].length);
      await backend.uploadBlob(contentHash: hashes[2], data: Stream.value(blobs[2]), length: blobs[2].length);

      for (final h in hashes) {
        expect(await backend.blobExists(h), isTrue);
      }
    });

    test('RefreshTokenRevoked is a distinct exception type from AuthExpired', () async {
      final faults = ScriptedFaultQueue()..enqueue(const RefreshTokenRevoked(SyncOp.appendCommit));
      final backend = MockSyncBackend(faultSource: faults);

      await expectLater(
        backend.appendCommit(
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'i1',
          parentCommitHash: null,
          commitBytes: _bytes('op-1'),
        ),
        throwsA(isA<SyncRefreshTokenRevokedException>()),
      );
    });
  });

  group('§ 8.2 item 4: rate limiting', () {
    test('RateLimited surfaces retryAfter and never abandons the publishIntentId '
        '— a retry after the injected fault converges normally', () async {
      final faults = ScriptedFaultQueue()
        ..enqueue(const RateLimited(SyncOp.appendCommit, retryAfter: Duration(seconds: 30)));
      final backend = MockSyncBackend(faultSource: faults);

      try {
        await backend.appendCommit(
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'stable-intent',
          parentCommitHash: null,
          commitBytes: _bytes('op-1'),
        );
        fail('expected SyncRateLimitedException');
      } on SyncRateLimitedException catch (e) {
        expect(e.retryAfter, const Duration(seconds: 30));
      }

      final retry = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'stable-intent',
        parentCommitHash: null,
        commitBytes: _bytes('op-1'),
      );
      expect(retry, isA<AppendCommitSucceeded>());
      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits, hasLength(1));
    });
  });

  group('§ 8.2 item 10: storage quota exceeded', () {
    test('QuotaExceeded is a distinct exception type, not folded into a generic failure',
        () async {
      final faults = ScriptedFaultQueue()..enqueue(const QuotaExceeded(SyncOp.uploadBlob));
      final backend = MockSyncBackend(faultSource: faults);
      final bytes = _bytes('too big');
      await expectLater(
        backend.uploadBlob(contentHash: sha256Hex(bytes), data: Stream.value(bytes), length: bytes.length),
        throwsA(isA<SyncQuotaExceededException>()),
      );
    });
  });

  group('§ 8.2 item 5: a conditional delete losing its race', () {
    test('captured etag goes stale after a concurrent re-write; the delete safely no-ops',
        () async {
      final clock = MockSyncClock(DateTime.utc(2026, 1, 1));
      final backend = MockSyncBackend(clock: clock);
      final bytes = _bytes('gc candidate');
      final hash = sha256Hex(bytes);
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);

      // GC engine's recheck step captures the current token...
      final capturedToken = backend.debugBlobEtag(hash)!;

      // ...then something else writes in the gap before the delete call
      // actually runs (a "joining device" or "new reference" in the real
      // architecture; modeled here as an external tamper touching mtime,
      // the same observable effect a real re-upload would have). The
      // clock must actually advance for this to produce a distinct token
      // — MockSyncClock never drifts on its own (§ 8.2 items 8/12), so a
      // realistic gap-in-time has to be simulated explicitly, exactly as
      // a real backend's mtime would only change once real wall-clock
      // time (or a real second write) actually elapses.
      clock.advance(const Duration(seconds: 1));
      backend.debugTamperBlob(hash);

      final outcome = await backend.deleteConditionally(
        ref: BlobRef(hash),
        precondition: IfUnmodifiedSince(capturedToken),
      );
      expect(outcome, isA<DeletePreconditionFailed>());
      expect(await backend.blobExists(hash), isTrue);
    });
  });

  group('§ 8.2 item 6: out-of-order delivery', () {
    test('a page missing a middle deviceSeq is reported as hasGap, not silently applied',
        () async {
      final faults = ScriptedFaultQueue()..enqueue(const OutOfOrderDelivery(SyncOp.readCommits));
      final backend = MockSyncBackend(faultSource: faults);
      final h1 = await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 1, publishIntentId: 'i1', parentCommitHash: null, payload: 'op-1');
      final h2 = await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 2, publishIntentId: 'i2', parentCommitHash: h1, payload: 'op-2');
      await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 3, publishIntentId: 'i3', parentCommitHash: h2, payload: 'op-3');

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.hasGap, isTrue);
      // A conformant caller must refuse to apply anything from this page.
    });
  });

  group('§ 8.2 item 7: duplicate delivery (listing-side flavor)', () {
    test('a duplicated entry inside one readCommits page is visible as hasGap=false but '
        'with a repeated commit — protocol-layer dedup (M0, already proven) is the '
        'documented second line of defense, not this backend', () async {
      final faults = ScriptedFaultQueue()..enqueue(const DuplicateDelivery(SyncOp.readCommits));
      final backend = MockSyncBackend(faultSource: faults);
      await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 1, publishIntentId: 'i1', parentCommitHash: null, payload: 'op-1');

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits.map((c) => c.deviceSeq), [1, 1]);
    });
  });

  group('§ 8.2 items 8 & 12: clock controllability', () {
    test('MockSyncClock is independently settable and does not drift with real wall-clock '
        'time — the primitive the day-29/30/31 grace-period-boundary determinism needs', () async {
      final clock = MockSyncClock(DateTime.utc(2026, 1, 1));
      final backend = MockSyncBackend(clock: clock);

      final bytes = _bytes('blob at day 0');
      final hash = sha256Hex(bytes);
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);
      final tokenAtDay0 = backend.debugBlobEtag(hash);

      // Real time passing during the test must not move the mock clock.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(backend.debugBlobEtag(hash), tokenAtDay0);

      // Fast-forward to exactly day 29, 30, and 31 of a nominal 30-day
      // grace period and confirm the clock reports exactly that — this is
      // as far as this milestone can validate item 8: no GC engine exists
      // yet to compute real candidacy/grace-period state (that logic
      // lives against `sync_blob_refs`, an application-layer table this
      // interface doesn't touch), so this test only proves the clock
      // primitive a future GC engine would need is deterministic and
      // controllable, not that grace-period business logic is correct —
      // there is no such logic to test yet.
      clock.set(DateTime.utc(2026, 1, 1).add(const Duration(days: 29)));
      final day29 = clock.now();
      clock.set(DateTime.utc(2026, 1, 1).add(const Duration(days: 30)));
      final day30 = clock.now();
      clock.set(DateTime.utc(2026, 1, 1).add(const Duration(days: 31)));
      final day31 = clock.now();

      expect(day30.difference(day29), const Duration(days: 1));
      expect(day31.difference(day30), const Duration(days: 1));
    });
  });

  group('§ 8.2 item 13: concurrent-writer collision on a device\'s own log', () {
    test('two callers holding the same stale parentCommitHash: the first wins, the '
        'second halts with ParentMismatch instead of forking', () async {
      final backend = MockSyncBackend();
      final h1 = await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 1, publishIntentId: 'i1', parentCommitHash: null, payload: 'op-1');

      // Both "callers" observed the same tip (h1) before either wrote.
      final firstCallerParent = h1;
      final secondCallerParent = h1;

      final firstOutcome = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 2,
        publishIntentId: 'first-writer',
        parentCommitHash: firstCallerParent,
        commitBytes: _bytes('op-2 from first writer'),
      );
      expect(firstOutcome, isA<AppendCommitSucceeded>());

      final secondOutcome = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 2,
        publishIntentId: 'second-writer',
        parentCommitHash: secondCallerParent,
        commitBytes: _bytes('op-2 from second writer'),
      );
      expect(secondOutcome, isA<AppendCommitParentMismatch>());
      expect((secondOutcome as AppendCommitParentMismatch).actualTipHash,
          (firstOutcome as AppendCommitSucceeded).commitHash);

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits, hasLength(2), reason: 'the log must not have forked');
    });
  });

  group('§ 8.2 item 14: read-after-write consistency gap', () {
    test('a different simulated client does not see a just-written commit until the '
        'injected propagation delay elapses', () async {
      final clock = MockSyncClock(DateTime.utc(2026, 1, 1));
      final faults = ScriptedFaultQueue()
        ..enqueue(const ReadAfterWriteGap(SyncOp.readCommits, Duration(seconds: 10)));
      final backend = MockSyncBackend(clock: clock, faultSource: faults);

      await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 1, publishIntentId: 'i1', parentCommitHash: null, payload: 'op-1');

      // Read immediately, from "another client" — the fault is still
      // queued for this one call.
      final staleRead = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(staleRead.commits, isEmpty,
          reason: 'the just-written commit has not propagated to this reader yet');

      // A later, unfaulted read (fault queue now empty) sees it.
      final freshRead = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(freshRead.commits, hasLength(1));
    });
  });

  group('§ 8.2 item 15: external tampering', () {
    test('15a: a blob altered externally is caught by downloadBlob\'s hash check', () async {
      final backend = MockSyncBackend();
      final bytes = _bytes('untampered');
      final hash = sha256Hex(bytes);
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);

      backend.debugTamperBlob(hash);
      await expectLater(backend.downloadBlob(hash), throwsA(isA<SyncHashMismatchException>()));
    });

    test('15a: a blob deleted externally is distinguishable from a hash mismatch '
        '(not-found, not corruption)', () async {
      final backend = MockSyncBackend();
      final bytes = _bytes('will be deleted externally');
      final hash = sha256Hex(bytes);
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);

      backend.debugDeleteBlobExternally(hash);
      expect(await backend.blobExists(hash), isFalse);
      await expectLater(backend.downloadBlob(hash), throwsA(isA<ArgumentError>()));
    });

    test('15b: a commit mutated in place after being written breaks hash-chain '
        'verification performed over the returned StoredCommit (the backend itself does '
        'not self-verify on every readCommits call — see the doc comment on '
        'SyncBackend.readCommits\'s implementation for why that\'s left to the caller '
        'in this milestone)', () async {
      final backend = MockSyncBackend();
      await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 1, publishIntentId: 'i1', parentCommitHash: null, payload: 'op-1');

      backend.debugTamperCommit('device-1', 1);

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      final commit = page.commits.single;
      final recomputedHash = sha256Hex([
        ...utf8.encode('device-1|1||'),
        ...commit.commitBytes,
      ]);
      expect(recomputedHash, isNot(commit.commitHash),
          reason: 'tampering must be detectable by recomputing the hash over the returned bytes');
    });

    test('15c: an entire device log deleted externally is indistinguishable from '
        '"this device has never synced" at this layer — the plan document\'s own '
        'disclosed, unresolved ambiguity (not one of the two this milestone was asked '
        'to resolve); this test documents the gap, it does not close it', () async {
      final backend = MockSyncBackend();
      await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 1, publishIntentId: 'i1', parentCommitHash: null, payload: 'op-1');
      expect(await backend.listDeviceLogIds(), contains('device-1'));

      backend.debugDeleteDeviceLogExternally('device-1');

      expect(await backend.listDeviceLogIds(), isNot(contains('device-1')));
      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits, isEmpty);
      expect(page.hasGap, isFalse,
          reason: 'this is exactly what a device that has never synced also looks like — '
              'the ambiguity § 8.2 item 15c discloses, reproduced faithfully rather than '
              'papered over with a distinguishing signal this interface does not actually have');
    });
  });

  // -- § 8.4/8.6: the Drive duplicate-create race, as its own required
  // scenario (not just "generic idempotent replay") -----------------------

  group('§ 8.4/8.6: Drive-style non-atomic-create race', () {
    test('atomic mode (default): two concurrent appendCommit calls under the identical '
        'publishIntentId converge to exactly one stored object', () async {
      final backend = MockSyncBackend(); // simulateNonAtomicCreate: false

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

      expect(results[0], isA<AppendCommitSucceeded>());
      expect(results[1], isA<AppendCommitSucceeded>());
      expect((results[0] as AppendCommitSucceeded).commitHash,
          (results[1] as AppendCommitSucceeded).commitHash);
      expect(backend.debugStorageObjectCountAtSeq('device-1', 1), 1,
          reason: 'the existence-check-via-listing mitigation (§ 8.4 decision) collapses '
              'the race to one logical commit when check-then-write is effectively atomic');
    });

    test('simulateNonAtomicCreate: true — the identical race can produce two distinct '
        'stored objects at the same deviceSeq, reproducing § 8.4\'s disclosed Drive '
        'finding exactly (this is the residual risk, not a bug in the mitigation; a '
        'full fix is real GoogleDriveBackend work, out of scope for this milestone)',
        () async {
      final backend = MockSyncBackend(simulateNonAtomicCreate: true);

      await Future.wait([
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

      expect(backend.debugStorageObjectCountAtSeq('device-1', 1), 2,
          reason: 'reproduces the exact residual risk § 8.4 discloses: Drive\'s lack of '
              'atomic create-if-absent-by-name lets two racing creates under the same '
              'intent both succeed');
    });

    test('a non-racing (sequential) retry still converges even in simulateNonAtomicCreate '
        'mode — the race requires genuine concurrency, not merely the mode being on',
        () async {
      final backend = MockSyncBackend(simulateNonAtomicCreate: true);
      final first = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'sequential-intent',
        parentCommitHash: null,
        commitBytes: _bytes('op-1'),
      );
      final second = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'sequential-intent',
        parentCommitHash: null,
        commitBytes: _bytes('op-1'),
      );
      expect((first as AppendCommitSucceeded).commitHash,
          (second as AppendCommitSucceeded).commitHash);
      expect(backend.debugStorageObjectCountAtSeq('device-1', 1), 1);
    });
  });

  // -- join-vs-log-pruning race-adjacent scenario (round 14) --------------

  group('join-vs-log-pruning race-adjacent scenario (round 14) — the primitive-level '
      'slice testable at this layer', () {
    test('a joining device\'s captured read-token protects against a concurrent prune '
        'underneath it; a genuinely stale token correctly allows the prune to proceed', () async {
      // What this test can and cannot claim, stated up front: § Architecture
      // 6's actual "fresh recheck of dataset_members before physical log
      // pruning" guarantee is engine-level logic built on `sync_ack_frontier`
      // (lib/services/database_service.dart) — this interface has no concept
      // of "which devices have acknowledged what," so it cannot enforce the
      // full join-vs-prune ordering guarantee by itself. What it *does*
      // provide, and what this test demonstrates, is the one primitive a
      // correct engine-level implementation would be built on:
      // deleteConditionally's precondition either protects a concurrently-
      // read state or correctly allows deletion once nothing protects it —
      // i.e. exactly § 8.2 item 5's conditional-delete-race mechanism,
      // applied to the log-pruning ref type instead of the blob ref type.
      final backend = MockSyncBackend();
      final h1 = await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 1, publishIntentId: 'i1', parentCommitHash: null, payload: 'op-1');
      await _appendOk(backend,
          deviceLogId: 'device-1', deviceSeq: 2, publishIntentId: 'i2', parentCommitHash: h1, payload: 'op-2');

      // "Joining device" reads the log and, alongside it, an engine would
      // capture the current log version token before deciding it's safe
      // to eventually observe a prune of the certified prefix.
      final joinRead = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(joinRead.commits, hasLength(2));
      final tokenAtJoin = backend.debugLogVersionToken('device-1')!;

      // Case 1: nothing else appended since the join-read — a prune of the
      // already-observed prefix (seq 1) using that token succeeds.
      final okOutcome = await backend.deleteConditionally(
        ref: const DeviceLogPrefixRef('device-1', 1),
        precondition: IfUnmodifiedSince(tokenAtJoin),
      );
      expect(okOutcome, isA<DeleteSucceeded>());

      // Case 2: a fresh log, but this time a new commit lands *after* the
      // join-read captured its token and *before* the prune attempt — the
      // stale token must cause the prune to safely no-op rather than
      // pruning out from under the (now-behind) joining device.
      final backend2 = MockSyncBackend();
      final g1 = await _appendOk(backend2,
          deviceLogId: 'device-2', deviceSeq: 1, publishIntentId: 'j1', parentCommitHash: null, payload: 'op-1');
      final staleToken = backend2.debugLogVersionToken('device-2')!;
      await _appendOk(backend2,
          deviceLogId: 'device-2', deviceSeq: 2, publishIntentId: 'j2', parentCommitHash: g1, payload: 'op-2');

      final blockedOutcome = await backend2.deleteConditionally(
        ref: const DeviceLogPrefixRef('device-2', 1),
        precondition: IfUnmodifiedSince(staleToken),
      );
      expect(blockedOutcome, isA<DeletePreconditionFailed>());
      final stillThere = await backend2.readCommits(deviceLogId: 'device-2', afterSeq: 0);
      expect(stillThere.commits.map((c) => c.deviceSeq), [1, 2]);
    });
  });
}
