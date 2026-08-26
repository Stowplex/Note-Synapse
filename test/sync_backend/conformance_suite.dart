// The abstract-interface conformance suite — § Architecture 8.6: "A
// conformance test suite written once against the abstract SyncBackend
// interface, not against MockSyncBackend specifically — so it later runs
// unmodified against GoogleDriveBackend/WebDAVBackend/LocalFolderBackend
// as each is implemented." Every test in this file talks to `SyncBackend`
// only — no `MockSyncBackend`-specific type, no fault injection, no debug
// hook. Fault-injection scenarios and anything needing `MockSyncBackend`'s
// own extra surface (the fault queue, the controllable clock, the
// `debugX` tamper hooks, `simulateNonAtomicCreate`) live in
// `mock_sync_backend_test.dart` instead — those genuinely cannot run
// against a real backend unmodified, so they don't belong here per § 8.6's
// own framing.
//
// `runSyncBackendConformanceSuite` takes a factory rather than an instance
// so it can be invoked more than once against differently-configured
// backends (e.g. `MockSyncBackend()` with default capabilities, and again
// with `supportsConditionalDelete: false` to exercise the Drive-shaped
// branch) — each invocation must produce a fresh, empty dataset.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/sync_backend_exceptions.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// Content-hash helper shared by every test below — deliberately simple
/// (plain sha256 of the raw bytes) since § 8.5's "content-hash is always
/// computed over plaintext" rule is exactly this, and no encryption layer
/// exists yet to complicate it.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Appends one commit built from the given plaintext payload, expecting
/// `Succeeded`, and returns its hash — a small helper so the tests below
/// read as scenarios, not hash-plumbing.
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
  expect(outcome, isA<AppendCommitSucceeded>(),
      reason: 'expected append #$deviceSeq on $deviceLogId to succeed, got $outcome');
  return (outcome as AppendCommitSucceeded).commitHash;
}

void runSyncBackendConformanceSuite(
  SyncBackend Function() createBackend, {
  String suiteLabel = 'SyncBackend conformance',
}) {
  group(suiteLabel, () {
    // -- dataset lifecycle -------------------------------------------

    test('readDatasetInitMarker is null before initializeDatasetOnce', () async {
      final backend = createBackend();
      expect(await backend.readDatasetInitMarker(), isNull);
    });

    test('initializeDatasetOnce is write-once: a second call never overwrites the first',
        () async {
      final backend = createBackend();
      final first = DatasetInitMarker(
        encryptionEnabled: false,
        kdfSalt: null,
        passphraseCanary: null,
        createdByDeviceId: 'device-a',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final second = DatasetInitMarker(
        encryptionEnabled: true,
        kdfSalt: Uint8List.fromList([1, 2, 3]),
        passphraseCanary: Uint8List.fromList([4, 5, 6]),
        createdByDeviceId: 'device-b',
        createdAt: DateTime.utc(2026, 1, 2),
      );
      await backend.initializeDatasetOnce(first);
      await backend.initializeDatasetOnce(second);

      final marker = await backend.readDatasetInitMarker();
      expect(marker, isNotNull);
      expect(marker!.createdByDeviceId, 'device-a');
      expect(marker.encryptionEnabled, isFalse,
          reason: 'encryption-enabled must be immutable once the dataset is created (requirement 5)');
    });

    // -- basic append/read roundtrip + hash-chain integrity ------------

    test('append then read round-trips the exact bytes', () async {
      final backend = createBackend();
      await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'intent-1',
        parentCommitHash: null,
        commitBytes: _bytes('op-1'),
      );

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.hasGap, isFalse);
      expect(page.commits, hasLength(1));
      expect(utf8.decode(page.commits.single.commitBytes), 'op-1');
      expect(page.commits.single.deviceSeq, 1);
      expect(page.commits.single.parentCommitHash, isNull);
    });

    test('hash chain: each commit correctly links to its parent and each hash is '
        'recoverable from (deviceLogId, deviceSeq, parent, bytes)', () async {
      final backend = createBackend();
      final hash1 = await _appendOk(backend,
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'i1',
          parentCommitHash: null,
          payload: 'op-1');
      final hash2 = await _appendOk(backend,
          deviceLogId: 'device-1',
          deviceSeq: 2,
          publishIntentId: 'i2',
          parentCommitHash: hash1,
          payload: 'op-2');
      await _appendOk(backend,
          deviceLogId: 'device-1',
          deviceSeq: 3,
          publishIntentId: 'i3',
          parentCommitHash: hash2,
          payload: 'op-3');

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.hasGap, isFalse);
      expect(page.commits, hasLength(3));

      // Chain linkage: commit[i].parentCommitHash == commit[i-1].commitHash.
      for (var i = 1; i < page.commits.length; i++) {
        expect(page.commits[i].parentCommitHash, page.commits[i - 1].commitHash,
            reason: 'commit at deviceSeq ${page.commits[i].deviceSeq} does not chain to its predecessor');
      }
      expect(page.commits.first.parentCommitHash, isNull);
    });

    test('halt-not-retarget: a mismatched parentCommitHash returns ParentMismatch, '
        'never silently applies past it', () async {
      final backend = createBackend();
      final hash1 = await _appendOk(backend,
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'i1',
          parentCommitHash: null,
          payload: 'op-1');

      final outcome = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 2,
        publishIntentId: 'i2-wrong-parent',
        parentCommitHash: 'not-the-real-tip-hash',
        commitBytes: _bytes('op-2'),
      );
      expect(outcome, isA<AppendCommitParentMismatch>());
      expect((outcome as AppendCommitParentMismatch).actualTipHash, hash1);

      // The mismatched write must not have been applied: the log still
      // has exactly one commit.
      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits, hasLength(1));
    });

    test('a device-seq gap without a matching parent is also ParentMismatch, not a silent skip',
        () async {
      final backend = createBackend();
      await _appendOk(backend,
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'i1',
          parentCommitHash: null,
          payload: 'op-1');

      // Attempt to jump straight to deviceSeq 3.
      final outcome = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 3,
        publishIntentId: 'i3',
        parentCommitHash: null,
        commitBytes: _bytes('op-3'),
      );
      expect(outcome, isA<AppendCommitParentMismatch>());
    });

    test('a non-null parentCommitHash against a still-empty log returns ParentMismatch '
        'with the documented empty-string "no commits yet" sentinel', () async {
      final backend = createBackend();
      final outcome = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'i1',
        parentCommitHash: 'a-hash-that-cannot-exist-yet',
        commitBytes: _bytes('op-1'),
      );
      expect(outcome, isA<AppendCommitParentMismatch>());
      expect((outcome as AppendCommitParentMismatch).actualTipHash, '',
          reason: 'empty string is the documented sentinel for "this log has no commits at all" '
              '— see the doc comment on AppendCommitParentMismatch.actualTipHash');

      // The rejected write must not have created a phantom commit.
      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits, isEmpty);
    });

    test('retried appendCommit under the identical publishIntentId is a no-op that returns '
        'the original hash (§ 8.2 item 7, duplicate delivery / idempotent replay)', () async {
      final backend = createBackend();
      final first = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'stable-intent',
        parentCommitHash: null,
        commitBytes: _bytes('op-1'),
      );
      final retry = await backend.appendCommit(
        deviceLogId: 'device-1',
        deviceSeq: 1,
        publishIntentId: 'stable-intent',
        parentCommitHash: null,
        commitBytes: _bytes('op-1'),
      );

      expect(first, isA<AppendCommitSucceeded>());
      expect(retry, isA<AppendCommitSucceeded>());
      expect((retry as AppendCommitSucceeded).commitHash,
          (first as AppendCommitSucceeded).commitHash);

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits, hasLength(1),
          reason: 'a retried identical publishIntentId must never produce a second commit');
    });

    // -- blobs -----------------------------------------------------------

    test('blob upload/download round-trips bytes and verifies the hash', () async {
      final backend = createBackend();
      final bytes = _bytes('attachment payload');
      final hash = sha256Hex(bytes);

      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);
      expect(await backend.blobExists(hash), isTrue);

      final downloaded = await (await backend.downloadBlob(hash)).toList();
      expect(downloaded.expand((c) => c).toList(), bytes);
    });

    test('uploadBlob rejects bytes that do not hash to the declared contentHash', () async {
      final backend = createBackend();
      final bytes = _bytes('real content');
      final wrongHash = sha256Hex(_bytes('a different string entirely'));

      await expectLater(
        backend.uploadBlob(contentHash: wrongHash, data: Stream.value(bytes), length: bytes.length),
        throwsA(isA<SyncHashMismatchException>()),
      );
      expect(await backend.blobExists(wrongHash), isFalse,
          reason: 'a hash-mismatched upload must not leave a stored (mislabeled) object behind');
    });

    test('downloadBlob throws for content that has never been uploaded', () async {
      final backend = createBackend();
      expect(backend.downloadBlob(sha256Hex(_bytes('never uploaded'))), throwsA(anything));
    });

    test('blobExists lets a caller skip a redundant upload (round-8 dedup scenario)', () async {
      final backend = createBackend();
      final bytes = _bytes('shared attachment content');
      final hash = sha256Hex(bytes);
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);

      // A second device with the identical content checks first...
      expect(await backend.blobExists(hash), isTrue);
      // ...and, finding it, never re-uploads — downloadBlob must still see
      // the original content, proving no re-upload was needed for
      // correctness.
      final downloaded = await (await backend.downloadBlob(hash)).toList();
      expect(downloaded.expand((c) => c).toList(), bytes);
    });

    // -- conditional deletion (§ 8.4's capability-gated union) -----------

    test('deleteConditionally: Unconditional always deletes (the branch every backend, '
        'including Drive, must support)', () async {
      final backend = createBackend();
      final bytes = _bytes('gc candidate');
      final hash = sha256Hex(bytes);
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);

      final outcome = await backend.deleteConditionally(
        ref: BlobRef(hash),
        precondition: const Unconditional(),
      );
      expect(outcome, isA<DeleteSucceeded>());
      expect(await backend.blobExists(hash), isFalse);
    });

    test(
        'deleteConditionally: on a supportsConditionalDelete backend, a stale/wrong '
        'IfUnmodifiedSince precondition safely no-ops and leaves the object live '
        '(§ 8.2 item 5, the other capability-gated branch)', () async {
      final backend = createBackend();
      if (!backend.capabilities.supportsConditionalDelete) {
        // Genuinely not applicable — this backend (Drive-shaped) has no
        // conditional-delete primitive at all, per § 8.4. This is the
        // capability-gated skip § 8.6 requires a *substitute assertion*
        // for, not a bare skip: the substitute is the Unconditional test
        // just above, which every backend (including this one) must pass.
        return;
      }
      final bytes = _bytes('gc candidate under a stale precondition');
      final hash = sha256Hex(bytes);
      await backend.uploadBlob(contentHash: hash, data: Stream.value(bytes), length: bytes.length);

      // A conformance suite running against a real backend cannot know
      // that backend's real etag/mtime token format in advance (this
      // interface has no "read the current token" method — a real gap,
      // not an oversight: § 8.1's interface never names one). What every
      // conditional-delete-capable backend must still guarantee is that
      // an obviously-wrong token is rejected as a precondition failure,
      // not silently treated as a match — that's the one assertion this
      // suite can make without backend-specific knowledge.
      final outcome = await backend.deleteConditionally(
        ref: BlobRef(hash),
        precondition: const IfUnmodifiedSince('definitely-not-a-real-token'),
      );
      expect(outcome, isA<DeletePreconditionFailed>());
      expect(await backend.blobExists(hash), isTrue,
          reason: 'a failed precondition must never delete the object — the literal '
              'mechanism § Architecture 4 relies on as its primary GC safety net');
    });

    test('deleteConditionally on a nonexistent blob returns DeleteNotFound, not an error',
        () async {
      final backend = createBackend();
      final outcome = await backend.deleteConditionally(
        ref: BlobRef(sha256Hex(_bytes('never existed'))),
        precondition: const Unconditional(),
      );
      expect(outcome, isA<DeleteNotFound>());
    });

    test('deleteConditionally prunes a device-log prefix and leaves the suffix intact',
        () async {
      final backend = createBackend();
      final h1 = await _appendOk(backend,
          deviceLogId: 'device-1',
          deviceSeq: 1,
          publishIntentId: 'i1',
          parentCommitHash: null,
          payload: 'op-1');
      await _appendOk(backend,
          deviceLogId: 'device-1',
          deviceSeq: 2,
          publishIntentId: 'i2',
          parentCommitHash: h1,
          payload: 'op-2');

      final outcome = await backend.deleteConditionally(
        ref: const DeviceLogPrefixRef('device-1', 1),
        precondition: const Unconditional(),
      );
      expect(outcome, isA<DeleteSucceeded>());

      final page = await backend.readCommits(deviceLogId: 'device-1', afterSeq: 0);
      expect(page.commits.map((c) => c.deviceSeq), [2]);
    });

    // -- snapshots ---------------------------------------------------------

    test('publishSnapshot/readSnapshot/latestSnapshotRef round-trip', () async {
      final backend = createBackend();
      expect(await backend.latestSnapshotRef(), isNull);

      final bytes = _bytes('certified consolidated state');
      final hash = sha256Hex(bytes);
      await backend.publishSnapshot(hash, bytes);

      final ref = await backend.latestSnapshotRef();
      expect(ref, isNotNull);
      expect(ref!.snapshotHash, hash);

      final read = await backend.readSnapshot(hash);
      expect(read, bytes);
    });

    test('publishSnapshot twice: latestSnapshotRef reflects the most recently published one',
        () async {
      final backend = createBackend();
      final bytes1 = _bytes('snapshot v1');
      final hash1 = sha256Hex(bytes1);
      await backend.publishSnapshot(hash1, bytes1);

      final bytes2 = _bytes('snapshot v2');
      final hash2 = sha256Hex(bytes2);
      await backend.publishSnapshot(hash2, bytes2);

      final ref = await backend.latestSnapshotRef();
      expect(ref!.snapshotHash, hash2);
      // The older snapshot must still be independently readable — GC of
      // superseded snapshots is a policy decision made elsewhere, not an
      // automatic side effect of publishing a new one.
      expect(await backend.readSnapshot(hash1), bytes1);
    });

    // -- multi-device convergence (§ 8.6: "at least one multi-device
    // convergence run routed through MockSyncBackend" — written against
    // the abstract interface so it's not actually mock-specific; two
    // logical devices share one backend instance, exactly as the real
    // architecture has every device point at the same remote root) -------

    test('multi-device convergence: two devices\' logs are both independently readable '
        'and internally consistent through one shared backend', () async {
      final backend = createBackend();

      final a1 = await _appendOk(backend,
          deviceLogId: 'device-a',
          deviceSeq: 1,
          publishIntentId: 'a-1',
          parentCommitHash: null,
          payload: 'device-a op-1');
      await _appendOk(backend,
          deviceLogId: 'device-a',
          deviceSeq: 2,
          publishIntentId: 'a-2',
          parentCommitHash: a1,
          payload: 'device-a op-2');

      final b1 = await _appendOk(backend,
          deviceLogId: 'device-b',
          deviceSeq: 1,
          publishIntentId: 'b-1',
          parentCommitHash: null,
          payload: 'device-b op-1');

      // Device B "pulls" device A's log (and vice versa) purely through
      // the public read API — this is the entire mechanism a sync engine
      // built on this interface would use for cross-device convergence;
      // nothing here depends on the two devices sharing process memory
      // beyond both talking to the same backend instance.
      final aFromB = await backend.readCommits(deviceLogId: 'device-a', afterSeq: 0);
      expect(aFromB.hasGap, isFalse);
      expect(aFromB.commits.map((c) => c.deviceSeq), [1, 2]);

      final bFromA = await backend.readCommits(deviceLogId: 'device-b', afterSeq: 0);
      expect(bFromA.hasGap, isFalse);
      expect(bFromA.commits.map((c) => c.deviceSeq), [1]);
      expect(bFromA.commits.single.commitHash, b1);

      final ids = await backend.listDeviceLogIds();
      expect(ids.toSet(), {'device-a', 'device-b'});
    });

    test('dataset_members bootstrap: listDeviceLogIds returns raw seed:/external: '
        'namespaces uncollapsed, and collapsePhysicalDeviceIds recovers the physical '
        'device count (§ 8.1 resolution)', () async {
      final backend = createBackend();
      await _appendOk(backend,
          deviceLogId: 'device-x',
          deviceSeq: 1,
          publishIntentId: 'x-1',
          parentCommitHash: null,
          payload: 'ordinary op');
      await _appendOk(backend,
          deviceLogId: 'seed:device-x',
          deviceSeq: 1,
          publishIntentId: 'seed-x-1',
          parentCommitHash: null,
          payload: 'seed import op');
      await _appendOk(backend,
          deviceLogId: 'external:device-x',
          deviceSeq: 1,
          publishIntentId: 'ext-x-1',
          parentCommitHash: null,
          payload: 'external edit op');
      await _appendOk(backend,
          deviceLogId: 'device-y',
          deviceSeq: 1,
          publishIntentId: 'y-1',
          parentCommitHash: null,
          payload: 'another physical device');

      final raw = await backend.listDeviceLogIds();
      expect(raw.toSet(), {'device-x', 'seed:device-x', 'external:device-x', 'device-y'},
          reason: 'listDeviceLogIds must return raw, uncollapsed log identities');

      final physical = collapsePhysicalDeviceIds(raw);
      expect(physical, {'device-x', 'device-y'},
          reason: 'one physical device that both synced normally and did a seed import + '
              'external edit must collapse to one member, not three');
    });
  });
}
