import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/crypto_service.dart';

void main() {
  final service = CryptoService();

  test('sha256 of text matches known vector', () {
    // Well-known SHA-256("abc").
    expect(
      service.digestHex('sha256', text: 'abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('sha1 of text matches known vector', () {
    expect(
      service.digestHex('sha1', text: 'abc'),
      'a9993e364706816aba3e25717850c26c9cd0d89d',
    );
  });

  test('accepts base64 input equivalent to text input', () {
    final b64 = base64Encode(utf8.encode('abc'));
    expect(
      service.digestHex('sha256', base64Data: b64),
      service.digestHex('sha256', text: 'abc'),
    );
  });

  test('algorithm name is case-insensitive', () {
    expect(
      service.digestHex('SHA256', text: 'abc'),
      service.digestHex('sha256', text: 'abc'),
    );
  });

  test('rejects an unsupported algorithm', () {
    expect(
      () => service.digestHex('md5', text: 'abc'),
      throwsArgumentError,
    );
  });

  test('requires an input', () {
    expect(() => service.digestHex('sha256'), throwsArgumentError);
  });
}
