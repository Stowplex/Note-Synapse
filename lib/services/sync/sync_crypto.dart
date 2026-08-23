// End-to-end encryption for a sync dataset — M3.3, requirement 5 and § 8.5
// of the CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// ---------------------------------------------------------------------
// **What was actually unencrypted, which is more than "attachments".**
// ---------------------------------------------------------------------
// § Architecture 4's one encryption-relevant sentence is scoped to blobs,
// and § 8.5 already flagged reading that literally as the trap: the COMMIT
// LOG carries note titles, note bodies, tag names and whole conversations as
// operation payloads, not as blobs. Until this file existed, a Drive folder
// holding a synced dataset was a plaintext copy of the user's notebook, and
// the settings screen said so in as many words.
//
// So encryption applies at the two byte boundaries where this engine hands
// content to a backend, and nowhere else:
//
//   * `commitBytes` — the operation payload (§ 11.5's JSON envelope);
//   * blob bytes — attachment files and `app_revisions.appCode` (M3.1/M3.2).
//
// ---------------------------------------------------------------------
// **What is deliberately NOT encrypted, stated plainly rather than left to
// be discovered.**
// ---------------------------------------------------------------------
// The cleartext framing § 8.5 specifies: `deviceLogId`, `deviceSeq`,
// `parentCommitHash`, `publishIntentId`, object names, and the
// `DatasetInitMarker` itself. A backend has to be able to validate an append
// and serve a log without decrypting anything, and the hash chain is what
// makes tampering detectable — both need the framing in the clear.
//
// The backend therefore still learns: which devices exist, when each one
// synced, how much it wrote, and which blobs are identical to which. That is
// the residual metadata leak every content-addressed store has, and it is
// disclosed here rather than defended.
//
// ---------------------------------------------------------------------
// **Content hashes stay over PLAINTEXT. This is a correctness requirement,
// not a preference.**
// ---------------------------------------------------------------------
// § Architecture 4 says so, and the reason is dedup: `blobExists` only saves
// an upload when two devices holding identical bytes compute the identical
// address. AEAD is non-deterministic by design (a fresh nonce per
// encryption), so hashing ciphertext would give the same file a different
// address on every device and on every re-encryption — content addressing
// would silently stop working, and nothing would fail loudly to say so.
//
// The consequence, which is the honest half: a backend that already holds a
// blob can confirm the plaintext hash matches a candidate it guesses. For a
// single user's own notebook that is a weak oracle; it is disclosed because
// it is a real difference from encrypting the address too.
//
// ---------------------------------------------------------------------
// **Choices, and what each one was chosen over.**
// ---------------------------------------------------------------------
//  * **AEAD: AES-GCM, 256-bit.** Over ChaCha20-Poly1305 because every
//    platform this app ships on has AES hardware acceleration, and because
//    it is the more conservative of the two "audited" options § 8.5 asks
//    for. Both are available in the same package; the choice is recorded in
//    one place ([_aead]) so it can be revisited without touching callers.
//  * **KDF: Argon2id**, memory-hard, per § 8.5's item 1 — the user chose a
//    passphrase-derived key over device-generated-plus-QR-transfer,
//    accepting a passphrase-guessing surface, which is exactly the surface a
//    memory-hard KDF exists to raise the cost of.
//  * **Parameters: 64 MiB, 3 passes, 1 lane.** § 8.5 left these open and
//    named the trade: join-time latency against brute-force resistance. 64
//    MiB is the RFC 9106 second-recommended option and is affordable on the
//    phones this app targets; deriving happens once per sync session, not
//    once per operation. **They are part of the dataset's format, not a
//    local preference** — a device that derived with different parameters
//    computes a different key from the same passphrase and would read the
//    canary as a wrong passphrase. So they are constants here and any change
//    to them is a dataset-format change.
//  * **Key lifetime: memory only, for the lifetime of a [SyncCrypto].**
//    § 11.1 left this open (memory-only versus OS-keychain-cached). Never
//    written to `sync_state`, never to the database, never to preferences —
//    the database is the thing a backup or a stolen device exposes, and a
//    key sitting in it would make the passphrase decorative.
//
// ---------------------------------------------------------------------
// **The canary, and why a wrong passphrase must fail HERE.**
// ---------------------------------------------------------------------
// Without one, a wrong passphrase surfaces as an AEAD authentication
// failure deep inside a pull, one commit at a time, indistinguishable from
// backend corruption or external tampering — which the engine is required to
// treat as a serious integrity error. So the marker carries a known
// plaintext encrypted under the dataset's key, and joining verifies it
// before any sync is attempted. A wrong passphrase is then exactly one
// clear failure at the moment the user typed it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Thrown when a passphrase does not open the dataset.
///
/// Distinct from any integrity exception on purpose: this one means "you
/// typed the wrong thing", and it is the only crypto failure a user can act
/// on. Everything else — a commit that fails to authenticate, a blob whose
/// tag does not verify — means the bytes are not what the author wrote, and
/// must never be reported as a passphrase problem.
class WrongPassphraseException implements Exception {
  const WrongPassphraseException();
  @override
  String toString() =>
      'WrongPassphraseException: this passphrase does not open the dataset';
}

/// Thrown when ciphertext fails to authenticate — corruption, truncation, or
/// tampering. Never a passphrase problem (the canary catches that first).
class SyncDecryptionFailedException implements Exception {
  const SyncDecryptionFailedException(this.what);
  final String what;
  @override
  String toString() =>
      'SyncDecryptionFailedException: $what did not authenticate — the bytes '
      'are not what the authoring device wrote';
}

/// The dataset-format constants. Changing any of them changes what key a
/// passphrase produces, so they are not tunable at runtime.
class SyncCryptoParams {
  static const int saltLengthBytes = 16;
  static const int keyLengthBytes = 32; // AES-256
  static const int nonceLengthBytes = 12; // AES-GCM's standard nonce

  /// RFC 9106's second recommended option, scaled to a phone: 64 MiB.
  static const int argon2MemoryKiB = 64 * 1024;
  static const int argon2Iterations = 3;
  static const int argon2Parallelism = 1;

  /// The plaintext the canary encrypts. Fixed, and deliberately not secret:
  /// its only job is to be something a correct key reproduces.
  static const String canaryPlaintext = 'note-synapse-sync-v1';
}

/// Encrypts and decrypts a dataset's bytes under a passphrase-derived key.
///
/// Construct via [deriveFromPassphrase] (which does the expensive KDF work
/// once) and hold it for the session.
class SyncCrypto {
  SyncCrypto._(this._key);

  final SecretKey _key;

  static final AesGcm _aead = AesGcm.with256bits();
  static final Argon2id _kdf = Argon2id(
    memory: SyncCryptoParams.argon2MemoryKiB,
    iterations: SyncCryptoParams.argon2Iterations,
    parallelism: SyncCryptoParams.argon2Parallelism,
    hashLength: SyncCryptoParams.keyLengthBytes,
  );

  /// Derives the dataset key. Expensive by design — that is the whole point
  /// of a memory-hard KDF — so call it once per session, not per operation.
  static Future<SyncCrypto> deriveFromPassphrase({
    required String passphrase,
    required Uint8List salt,
  }) async {
    final key = await _kdf.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
    return SyncCrypto._(key);
  }

  /// A fresh random salt for a new dataset.
  static Uint8List newSalt() => Uint8List.fromList(
    SecretKeyData.random(length: SyncCryptoParams.saltLengthBytes).bytes,
  );

  /// The canary a new dataset records in its [DatasetInitMarker].
  Future<Uint8List> buildCanary() =>
      encryptBytes(utf8.encode(SyncCryptoParams.canaryPlaintext), 'canary');

  /// Verifies this key against a dataset's recorded canary.
  ///
  /// Throws [WrongPassphraseException] — never the generic decryption
  /// failure — because at this point the only variable is the passphrase:
  /// the marker was just read from the backend and its ciphertext is as the
  /// creating device wrote it.
  Future<void> verifyCanary(Uint8List canary) async {
    Uint8List plaintext;
    try {
      plaintext = await decryptBytes(canary, 'canary');
    } catch (_) {
      throw const WrongPassphraseException();
    }
    if (utf8.decode(plaintext, allowMalformed: true) !=
        SyncCryptoParams.canaryPlaintext) {
      throw const WrongPassphraseException();
    }
  }

  /// `[nonce] || [ciphertext+tag]` — § 8.5's on-backend layout.
  ///
  /// The nonce is fresh per call and stored alongside, which is what makes
  /// the same plaintext encrypt differently every time. That is required for
  /// AES-GCM's security and is exactly why a content hash must be taken over
  /// the plaintext instead (see this file's header).
  Future<Uint8List> encryptBytes(List<int> plaintext, String what) async {
    final box = await _aead.encrypt(plaintext, secretKey: _key);
    final out = BytesBuilder(copy: false)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  Future<Uint8List> decryptBytes(Uint8List sealed, String what) async {
    const nonceLength = SyncCryptoParams.nonceLengthBytes;
    final macLength = _aead.macAlgorithm.macLength;
    if (sealed.length < nonceLength + macLength) {
      throw SyncDecryptionFailedException(what);
    }
    final box = SecretBox(
      sealed.sublist(nonceLength, sealed.length - macLength),
      nonce: sealed.sublist(0, nonceLength),
      mac: Mac(sealed.sublist(sealed.length - macLength)),
    );
    try {
      return Uint8List.fromList(await _aead.decrypt(box, secretKey: _key));
    } catch (_) {
      throw SyncDecryptionFailedException(what);
    }
  }
}

/// What a sync session needs to know about encryption, resolved once at
/// bootstrap: either the dataset is plaintext, or here is the key.
///
/// **A single nullable [SyncCrypto] rather than a flag plus a key**, so
/// "encryption is on but no key was derived" is not representable. Every
/// byte boundary asks the same question — `crypto == null ? bytes :
/// encrypt(bytes)` — and cannot get it half-right.
class DatasetCrypto {
  const DatasetCrypto(this.crypto);
  const DatasetCrypto.plaintext() : crypto = null;

  final SyncCrypto? crypto;

  bool get isEncrypted => crypto != null;

  Future<Uint8List> seal(List<int> plaintext, String what) async =>
      crypto == null
      ? Uint8List.fromList(plaintext)
      : crypto!.encryptBytes(plaintext, what);

  Future<Uint8List> open(Uint8List stored, String what) async =>
      crypto == null ? stored : crypto!.decryptBytes(stored, what);
}
