import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Handles all encryption/decryption for the sync layer.
///
/// Used to encrypt oplog files, snapshots, and attachments before writing
/// to remote storage, and to compute/verify HMACs on sync-config.json
/// for anti-downgrade protection.
class SyncEncryptionService {
  final SecretKey _derivedKey;
  final String _cipherId;

  SyncEncryptionService._(this._derivedKey, this._cipherId);

  /// Creates a [SyncEncryptionService] by deriving a 256-bit key from the
  /// given [passphrase] and [salt] using Argon2id.
  ///
  /// [cipherId] must be either 'aes-256-gcm' or 'xchacha20-poly1305'.
  /// [salt] must be a base64-encoded salt string.
  static Future<SyncEncryptionService> create({
    required String passphrase,
    required String cipherId,
    required String salt,
    int kdfMemory = 65536,
    int kdfIterations = 3,
    int kdfParallelism = 4,
  }) async {
    assert(
      cipherId == 'aes-256-gcm' || cipherId == 'xchacha20-poly1305',
      'cipherId must be "aes-256-gcm" or "xchacha20-poly1305"',
    );

    final derivedKeyBytes = await compute(_deriveKey, {
      'passphrase': passphrase,
      'salt': salt,
      'memory': kdfMemory,
      'iterations': kdfIterations,
      'parallelism': kdfParallelism,
    });

    return SyncEncryptionService._(SecretKey(derivedKeyBytes), cipherId);
  }

  /// execution in isolate
  static Future<List<int>> _deriveKey(Map<String, dynamic> args) async {
    final passphrase = args['passphrase'] as String;
    final salt = args['salt'] as String;
    final memory = args['memory'] as int;
    final iterations = args['iterations'] as int;
    final parallelism = args['parallelism'] as int;

    final argon2 = Argon2id(
      memory: memory,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: 32,
    );

    final secretKey = await argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: base64Decode(salt),
    );

    return secretKey.extractBytes();
  }

  /// Returns the cipher instance based on the configured [_cipherId].
  Cipher _getCipher() {
    switch (_cipherId) {
      case 'aes-256-gcm':
        return AesGcm.with256bits();
      case 'xchacha20-poly1305':
        return Xchacha20.poly1305Aead();
      default:
        throw StateError('Unsupported cipher: $_cipherId');
    }
  }

  /// Encrypts the given [plaintext] using the configured cipher.
  ///
  /// The result is packed as:
  /// `[1 byte nonce length][nonce bytes][16 bytes MAC][ciphertext bytes]`
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final cipher = _getCipher();
    final secretBox = await cipher.encrypt(plaintext, secretKey: _derivedKey);

    final nonce = secretBox.nonce;
    final mac = secretBox.mac.bytes;
    final ciphertext = secretBox.cipherText;

    // Pack: [1 byte nonce length][nonce][16 bytes MAC][ciphertext]
    final result = BytesBuilder(copy: false);
    result.addByte(nonce.length);
    result.add(nonce);
    result.add(mac);
    result.add(ciphertext);

    return result.toBytes();
  }

  /// Decrypts the given [packed] bytes that were produced by [encrypt].
  ///
  /// Unpacks: read nonce length from first byte, extract nonce, MAC (16 bytes),
  /// and ciphertext, then decrypts with the derived key.
  Future<Uint8List> decrypt(Uint8List packed) async {
    final cipher = _getCipher();

    // Unpack
    if (packed.isEmpty) {
      throw const FormatException('Cannot decrypt empty data');
    }

    final nonceLength = packed[0];
    // Min length: 1 (length byte) + nonceLength + 16 (MAC)
    final minLength = 1 + nonceLength + 16;
    if (packed.length < minLength) {
      throw FormatException(
        'Invalid packed data length: ${packed.length}, expected at least $minLength',
      );
    }

    final nonce = packed.sublist(1, 1 + nonceLength);
    final mac = packed.sublist(1 + nonceLength, 1 + nonceLength + 16);
    final ciphertext = packed.sublist(1 + nonceLength + 16);

    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));

    final decrypted = await cipher.decrypt(secretBox, secretKey: _derivedKey);

    return Uint8List.fromList(decrypted);
  }

  /// Computes an HMAC-SHA256 of the given [data] using the derived key.
  ///
  /// Returns the MAC as a base64-encoded string.
  Future<String> computeHmac(String data) async {
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      utf8.encode(data),
      secretKey: _derivedKey,
    );
    return base64Encode(mac.bytes);
  }

  /// Verifies that the HMAC of [data] matches [expectedHmac].
  Future<bool> verifyHmac(String data, String expectedHmac) async {
    final computed = await computeHmac(data);
    return computed == expectedHmac;
  }

  /// Helper to get raw key bytes for passing to isolates.
  Future<List<int>> getDerivedKeyBytes() async {
    return _derivedKey.extractBytes();
  }

  String getCipherId() => _cipherId;

  // Placeholder - current implementation doesn't store salt on instance
  Future<String?> getSalt() async => null;
}
