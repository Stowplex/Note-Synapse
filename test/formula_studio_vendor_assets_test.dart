import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Formula Studio vendor files match the reviewed SHA-256 pins', () {
    final lock =
        jsonDecode(
              File(
                'contrib/formula-studio/vendor-lock.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    for (final package in lock.values.cast<Map<String, dynamic>>()) {
      final files = package['files'] as Map<String, dynamic>;
      for (final entry in files.entries) {
        final file = File(entry.key);
        expect(file.existsSync(), isTrue, reason: '${entry.key} is missing');
        expect(
          sha256.convert(file.readAsBytesSync()).toString(),
          entry.value,
          reason: '${entry.key} does not match its reviewed vendor pin',
        );
      }
    }
  });

  test('Formula Studio dependencies and licenses are packaged as assets', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/scripts/mathlive/'));
    expect(pubspec, contains('- assets/scripts/mathlive/fonts/'));
    expect(pubspec, contains('- assets/scripts/compute-engine/'));

    expect(File('assets/scripts/mathlive/LICENSE.txt').existsSync(), isTrue);
    expect(
      File('assets/scripts/compute-engine/LICENSE.txt').existsSync(),
      isTrue,
    );
  });
}
