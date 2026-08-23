// M3.3 — the crypto core: KDF, AEAD, and the canary.
//
// These are the properties the rest of the encryption work rests on, so
// they are pinned directly rather than only through an end-to-end sync.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/sync_crypto.dart';

void main() {
  // Argon2id at 64 MiB is deliberately expensive; a handful of derivations
  // per test file is fine, but the default 30s timeout is not.
  const slow = Timeout(Duration(minutes: 3));

  late Uint8List salt;
  late SyncCrypto alice;

  setUpAll(() async {
    salt = SyncCrypto.newSalt();
    alice = await SyncCrypto.deriveFromPassphrase(
      passphrase: 'correct horse battery staple',
      salt: salt,
    );
  });

  test('a round trip returns exactly the plaintext', () async {
    final sealed = await alice.encryptBytes(utf8.encode('note body'), 'test');
    expect(
      utf8.decode(await alice.decryptBytes(sealed, 'test')),
      'note body',
    );
  }, timeout: slow);

  test(
    'the same plaintext encrypts differently every time — which is WHY '
    'content hashes are taken over plaintext',
    () async {
      final a = await alice.encryptBytes(utf8.encode('same'), 'test');
      final b = await alice.encryptBytes(utf8.encode('same'), 'test');
      expect(
        a,
        isNot(equals(b)),
        reason:
            'a fresh nonce per encryption is required for AES-GCM. Hashing '
            'ciphertext would therefore give one file a different address on '
            'every device, and blobExists dedup would silently stop working '
            'with nothing failing loudly to say so.',
      );
      expect(utf8.decode(await alice.decryptBytes(b, 'test')), 'same');
    },
    timeout: slow,
  );

  test('the ciphertext does not contain the plaintext', () async {
    final sealed = await alice.encryptBytes(
      utf8.encode('SECRET_NOTE_TITLE'),
      'test',
    );
    expect(
      String.fromCharCodes(sealed).contains('SECRET_NOTE_TITLE'),
      isFalse,
    );
  }, timeout: slow);

  test('a different passphrase derives a different key', () async {
    final mallory = await SyncCrypto.deriveFromPassphrase(
      passphrase: 'wrong passphrase',
      salt: salt,
    );
    final sealed = await alice.encryptBytes(utf8.encode('x'), 'test');
    await expectLater(
      mallory.decryptBytes(sealed, 'test'),
      throwsA(isA<SyncDecryptionFailedException>()),
    );
  }, timeout: slow);

  test('the same passphrase with a different salt derives a different key',
      () async {
    final other = await SyncCrypto.deriveFromPassphrase(
      passphrase: 'correct horse battery staple',
      salt: SyncCrypto.newSalt(),
    );
    final sealed = await alice.encryptBytes(utf8.encode('x'), 'test');
    await expectLater(
      other.decryptBytes(sealed, 'test'),
      throwsA(isA<SyncDecryptionFailedException>()),
    );
  }, timeout: slow);

  test(
    'a wrong passphrase fails the canary as a PASSPHRASE error, not as an '
    'integrity error',
    () async {
      final canary = await alice.buildCanary();
      await alice.verifyCanary(canary); // the right key opens it

      final mallory = await SyncCrypto.deriveFromPassphrase(
        passphrase: 'not it',
        salt: salt,
      );
      await expectLater(
        mallory.verifyCanary(canary),
        throwsA(isA<WrongPassphraseException>()),
        reason:
            'without the canary a wrong passphrase surfaces as an AEAD '
            'authentication failure deep inside a pull, one commit at a '
            'time, indistinguishable from corruption or tampering — which '
            'the engine must treat as a serious integrity error',
      );
    },
    timeout: slow,
  );

  test('tampered ciphertext is rejected, and is NOT called a passphrase '
      'problem', () async {
    final sealed = await alice.encryptBytes(utf8.encode('payload'), 'commit');
    sealed[sealed.length - 1] ^= 0xFF; // flip a bit in the tag
    await expectLater(
      alice.decryptBytes(sealed, 'commit'),
      throwsA(isA<SyncDecryptionFailedException>()),
    );
  }, timeout: slow);

  test('truncated ciphertext is rejected rather than read out of range',
      () async {
    final sealed = await alice.encryptBytes(utf8.encode('payload'), 'commit');
    await expectLater(
      alice.decryptBytes(sealed.sublist(0, 4), 'commit'),
      throwsA(isA<SyncDecryptionFailedException>()),
    );
  }, timeout: slow);

  test('DatasetCrypto.plaintext is a pass-through, byte for byte', () async {
    const plain = DatasetCrypto.plaintext();
    expect(plain.isEncrypted, isFalse);
    final bytes = utf8.encode('unchanged');
    expect(await plain.seal(bytes, 'x'), equals(bytes));
    expect(
      await plain.open(Uint8List.fromList(bytes), 'x'),
      equals(bytes),
      reason:
          'an unencrypted dataset must produce byte-identical output to the '
          'pre-M3.3 engine, or every existing backend would stop being '
          'readable',
    );
  });

  test('salts are random and the documented length', () {
    final a = SyncCrypto.newSalt();
    final b = SyncCrypto.newSalt();
    expect(a, hasLength(SyncCryptoParams.saltLengthBytes));
    expect(a, isNot(equals(b)));
  });
}
