import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Central hashing so plugin JS (`Synapse.crypto.digest`) and Dart callers
/// produce byte-identical digests from one implementation.
///
/// Exists because user apps run in a custom-scheme WebView where the Web Crypto
/// API (`crypto.subtle`) is unavailable (non-secure context); rather than ship a
/// JS polyfill, hashing is delegated to Dart's `package:crypto`.
class CryptoService {
  /// Returns the lowercase hex digest of the input under [algorithm]
  /// (`'sha1'` or `'sha256'`). Provide exactly one of [text] or [base64Data].
  String digestHex(
    String algorithm, {
    String? text,
    String? base64Data,
  }) {
    final Uint8List bytes;
    if (text != null) {
      bytes = Uint8List.fromList(utf8.encode(text));
    } else if (base64Data != null) {
      bytes = base64Decode(base64Data);
    } else {
      throw ArgumentError('Either text or base64Data must be provided');
    }

    final Hash hasher;
    switch (algorithm.toLowerCase()) {
      case 'sha1':
        hasher = sha1;
        break;
      case 'sha256':
        hasher = sha256;
        break;
      default:
        throw ArgumentError(
          "Unsupported digest algorithm: '$algorithm' (use 'sha1' or 'sha256')",
        );
    }
    return hasher.convert(bytes).toString();
  }
}
