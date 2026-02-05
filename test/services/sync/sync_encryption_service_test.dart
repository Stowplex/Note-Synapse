import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/sync_encryption_service.dart';

void main() {
  // Use low KDF params so tests run fast.
  const lowMemory = 1024;
  const lowIterations = 1;
  const lowParallelism = 1;

  final testSalt = base64Encode(utf8.encode('test-salt-16bytes'));

  Future<SyncEncryptionService> createService({
    String passphrase = 'test-passphrase',
    String cipherId = 'aes-256-gcm',
    String? salt,
  }) {
    return SyncEncryptionService.create(
      passphrase: passphrase,
      cipherId: cipherId,
      salt: salt ?? testSalt,
      kdfMemory: lowMemory,
      kdfIterations: lowIterations,
      kdfParallelism: lowParallelism,
    );
  }

  group('AES-256-GCM', () {
    test('encrypt then decrypt returns original data', () async {
      final service = await createService();
      final plaintext = utf8.encode('Hello, World!');
      final packed = await service.encrypt(Uint8List.fromList(plaintext));
      final decrypted = await service.decrypt(packed);
      expect(decrypted, equals(Uint8List.fromList(plaintext)));
    });

    test('different plaintexts produce different ciphertexts', () async {
      final service = await createService();
      final packed1 =
          await service.encrypt(Uint8List.fromList(utf8.encode('message A')));
      final packed2 =
          await service.encrypt(Uint8List.fromList(utf8.encode('message B')));
      expect(packed1, isNot(equals(packed2)));
    });

    test('same plaintext encrypted twice produces different ciphertexts (random IV)',
        () async {
      final service = await createService();
      final plaintext = Uint8List.fromList(utf8.encode('same message'));
      final packed1 = await service.encrypt(plaintext);
      final packed2 = await service.encrypt(plaintext);
      expect(packed1, isNot(equals(packed2)));
    });

    test('decrypt with wrong key throws', () async {
      final service1 = await createService(passphrase: 'correct-passphrase');
      final service2 = await createService(passphrase: 'wrong-passphrase');
      final plaintext = Uint8List.fromList(utf8.encode('secret'));
      final packed = await service1.encrypt(plaintext);
      expect(() => service2.decrypt(packed), throwsA(anything));
    });

    test('handles empty data', () async {
      final service = await createService();
      final plaintext = Uint8List(0);
      final packed = await service.encrypt(plaintext);
      final decrypted = await service.decrypt(packed);
      expect(decrypted, equals(Uint8List(0)));
    });

    test('handles large data (1MB)', () async {
      final service = await createService();
      final plaintext = Uint8List(1024 * 1024); // 1MB of zeros
      for (var i = 0; i < plaintext.length; i++) {
        plaintext[i] = i % 256;
      }
      final packed = await service.encrypt(plaintext);
      final decrypted = await service.decrypt(packed);
      expect(decrypted, equals(plaintext));
    });
  });

  group('XChaCha20-Poly1305', () {
    test('encrypt then decrypt returns original data', () async {
      final service =
          await createService(cipherId: 'xchacha20-poly1305');
      final plaintext = utf8.encode('Hello, XChaCha20!');
      final packed = await service.encrypt(Uint8List.fromList(plaintext));
      final decrypted = await service.decrypt(packed);
      expect(decrypted, equals(Uint8List.fromList(plaintext)));
    });
  });

  group('HMAC', () {
    test('computeHmac produces consistent output for same input', () async {
      final service = await createService();
      final hmac1 = await service.computeHmac('test data');
      final hmac2 = await service.computeHmac('test data');
      expect(hmac1, equals(hmac2));
    });

    test('verifyHmac returns true for valid HMAC', () async {
      final service = await createService();
      final hmac = await service.computeHmac('test data');
      final result = await service.verifyHmac('test data', hmac);
      expect(result, isTrue);
    });

    test('verifyHmac returns false for tampered data', () async {
      final service = await createService();
      final hmac = await service.computeHmac('original data');
      final result = await service.verifyHmac('tampered data', hmac);
      expect(result, isFalse);
    });
  });

  group('Key derivation', () {
    test('same passphrase + salt produces same key (encrypt on one, decrypt on another)',
        () async {
      final service1 = await createService(
        passphrase: 'shared-passphrase',
        salt: testSalt,
      );
      final service2 = await createService(
        passphrase: 'shared-passphrase',
        salt: testSalt,
      );
      final plaintext = Uint8List.fromList(utf8.encode('cross-instance'));
      final packed = await service1.encrypt(plaintext);
      final decrypted = await service2.decrypt(packed);
      expect(decrypted, equals(plaintext));
    });
  });
}
