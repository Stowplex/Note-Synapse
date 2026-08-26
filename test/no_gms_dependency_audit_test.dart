// M2.9 — permanent audit: no Google Play Services anywhere in the Android
// build.
//
// **Why this test exists.** Locked-in product requirement 12 forbids any
// dependency on Google Play Services / GMS. The Drive sync feature added in
// M2.9 is exactly the kind of feature that normally drags GMS in: the
// obvious way to do "sign in with Google" on Android is `google_sign_in`
// (which depends on `play-services-auth`), Credential Manager, or One Tap,
// and the obvious way to do "cloud storage" is Firebase. M2.9 deliberately
// did none of that — it uses plain HTTPS plus a custom URL scheme built from
// `url_launcher`/`app_links`/`http`/`crypto`. That decision is invisible in
// the code once made; the failure mode is a *future* change adding one line
// to `pubspec.yaml` and nobody noticing until a GMS-less device (or a
// de-Googled ROM, or an F-Droid build) breaks. This test is the tripwire.
//
// ============================================================================
// WHAT THIS TEST PROVES — read this before citing it as evidence
// ============================================================================
//
// It proves, exactly:
//
//   (A) No file in this repository's Android build configuration
//       (`android/**` Gradle scripts, `gradle.properties`, the app manifest,
//       and any Android source under `android/app/src`) mentions a banned
//       coordinate (`com.google.android.gms`, `play-services-*`,
//       `com.google.firebase`, `firebase-*`, the `com.google.gms.google-services`
//       Gradle plugin, or `google-services.json`).
//
//   (B) No package listed in `pubspec.yaml` is on the banned-plugin list
//       (`google_sign_in`, `firebase_*`, `google_api_availability`,
//       `flutter_appauth`, ...).
//
//   (C) For every Flutter plugin with an Android implementation that this
//       app actually resolves — read from `.flutter-plugins-dependencies`,
//       which `flutter pub get` generates and which includes TRANSITIVE
//       plugin dependencies, not just direct ones — that plugin's own
//       Gradle files (`build.gradle` / `build.gradle.kts`, at any depth in
//       its `android/` directory) contain no banned coordinate either.
//       This is the part that makes the check meaningfully transitive at
//       the Flutter-plugin level: it is what would catch someone adding a
//       package that itself pulls `play-services-auth`.
//
// Comment-only lines are skipped (so a "we deliberately do not use GMS" note
// cannot trip the scan), and [kReviewedExceptions] holds a small, individually
// justified allowlist of occurrences that are demonstrably not dependencies —
// each entry must match both a path fragment and a line fragment, so nothing
// is blanket-exempted.
//
// It does NOT prove:
//
//   * That a full Gradle dependency resolution (`./gradlew :app:dependencies`)
//     is GMS-free. Running Gradle from a `flutter test` process is not
//     feasible here: it needs the Android SDK, a JVM toolchain, and network
//     access to resolve Maven coordinates, and takes minutes. A dependency
//     pulled in ONLY as a transitive *Maven* dependency of some non-Flutter
//     AAR — i.e. one that is never named in any Gradle file this test can
//     read — would not be caught. The realistic paths into this codebase
//     (a new pub package, or a hand-edited Gradle file) ARE covered; a
//     third-party AAR quietly depending on GMS internally is not.
//   * Anything about the iOS build (GMS is Android-only, so this is not a
//     gap so much as a non-question).
//   * That the shipped APK contains no GMS classes. Only a build-output scan
//     could show that, and there is no build output in a unit-test run.
//
// If you need the stronger guarantee, run
// `cd android && ./gradlew :app:dependencies` and grep the output by hand —
// that is the check this test is a fast, offline approximation of, and the
// approximation is deliberate, not an oversight.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Maven/Gradle coordinate fragments that indicate Google Play Services or
/// Firebase (which itself depends on GMS on Android).
const List<String> kBannedGradleTokens = [
  'com.google.android.gms',
  'play-services',
  'com.google.firebase',
  'firebase-android-sdk',
  'com.google.gms.google-services',
  'google-services.json',
  'com.google.android.libraries.identity',
  'androidx.credentials',
];

/// Pub packages that pull GMS in (directly or transitively) on Android, plus
/// `flutter_appauth`, which is banned for a different reason: M2.9's brief
/// rules it out explicitly as unnecessary given the flow already built.
const List<String> kBannedPubPackages = [
  'google_sign_in',
  'google_sign_in_android',
  'googleapis_auth',
  'google_api_availability',
  'firebase_core',
  'firebase_auth',
  'firebase_analytics',
  'firebase_messaging',
  'firebase_crashlytics',
  'flutter_appauth',
  'play_integrity',
  'google_mobile_ads',
];

/// Known, reviewed, benign occurrences that are NOT dependencies.
///
/// Each entry is `(file-path substring, line substring)`; a hit is dropped
/// only if BOTH match, so an allowlist entry can never blanket-exempt a
/// whole file. Adding one is a deliberate act that should come with the
/// reasoning, as below.
const List<(String, String)> kReviewedExceptions = [
  // `image_picker_android` declares a `<service>`/`<action>` for
  // `com.google.android.gms.metadata.ModuleDependencies` in its manifest.
  // This is the Android Photo Picker "module dependencies" declaration: it
  // is a *manifest marker* that Play Services, IF PRESENT on the device,
  // reads in order to install the photopicker module. It adds no Maven
  // dependency, no `play-services-*` artifact, and no code — the plugin's
  // own Gradle files pull nothing from GMS (which this test verifies
  // independently, since only the manifest lines are excepted here). On a
  // device without Play Services it is inert: nothing looks for it, and
  // image picking falls back to the platform picker. Reviewed for M2.9;
  // the app still installs and runs GMS-free.
  (
    'image_picker_android',
    'com.google.android.gms.metadata.ModuleDependencies',
  ),
  (
    'image_picker_android',
    'com.google.android.gms.metadata.MODULE_DEPENDENCIES',
  ),
];

bool _isReviewedException(String label, String line) {
  for (final (pathPart, linePart) in kReviewedExceptions) {
    if (label.contains(pathPart) && line.contains(linePart)) return true;
  }
  return false;
}

/// A single banned-token hit, for a readable failure message.
class _Hit {
  _Hit(this.file, this.line, this.token, this.text);
  final String file;
  final int line;
  final String token;
  final String text;

  @override
  String toString() => '$file:$line  [$token]  ${text.trim()}';
}

List<_Hit> _scanFileForBannedTokens(File file, {required String label}) {
  final hits = <_Hit>[];
  final String content;
  try {
    content = file.readAsStringSync();
  } on FileSystemException {
    return hits; // Binary/unreadable file — nothing to assert about.
  }
  final lines = const LineSplitter().convert(content);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    // Skip comment-only lines: this very test's own explanatory comments,
    // and any legitimate "we deliberately do NOT use GMS" note in a Gradle
    // file, must not trip the scan.
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//') ||
        trimmed.startsWith('#') ||
        trimmed.startsWith('*') ||
        trimmed.startsWith('/*') ||
        trimmed.startsWith('<!--')) {
      continue;
    }
    if (_isReviewedException(label, line)) continue;
    for (final token in kBannedGradleTokens) {
      if (line.contains(token)) {
        hits.add(_Hit(label, i + 1, token, line));
      }
    }
  }
  return hits;
}

List<File> _gradleAndConfigFilesUnder(Directory dir) {
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) {
        final name = f.path.split(Platform.pathSeparator).last;
        // Skip build outputs and Gradle's own caches — they are generated,
        // not authored, and can legitimately mention anything.
        if (f.path.contains(
              '${Platform.pathSeparator}build${Platform.pathSeparator}',
            ) ||
            f.path.contains(
              '${Platform.pathSeparator}.gradle${Platform.pathSeparator}',
            )) {
          return false;
        }
        return name.endsWith('.gradle') ||
            name.endsWith('.gradle.kts') ||
            name == 'gradle.properties' ||
            name == 'AndroidManifest.xml' ||
            name.endsWith('.pro') ||
            name == 'settings.gradle' ||
            name == 'settings.gradle.kts';
      })
      .toList();
}

void main() {
  group('No Google Play Services dependency (locked-in requirement 12)', () {
    test('(A) this repo\'s own Android build config names no GMS coordinate', () {
      final androidDir = Directory('android');
      expect(
        androidDir.existsSync(),
        isTrue,
        reason: 'android/ not found — run this test from the project root.',
      );

      final files = _gradleAndConfigFilesUnder(androidDir);
      expect(
        files,
        isNotEmpty,
        reason:
            'Found no Gradle/manifest files under android/ — the scan '
            'would vacuously pass, which is worse than failing.',
      );

      final hits = <_Hit>[];
      for (final file in files) {
        hits.addAll(_scanFileForBannedTokens(file, label: file.path));
      }

      // google-services.json is the Firebase config file; its mere presence
      // means someone wired Firebase up even if no Gradle file mentions it.
      for (final candidate in const [
        'android/app/google-services.json',
        'android/google-services.json',
      ]) {
        if (File(candidate).existsSync()) {
          hits.add(_Hit(candidate, 0, 'google-services.json', 'file exists'));
        }
      }

      expect(
        hits,
        isEmpty,
        reason:
            'Google Play Services / Firebase coordinates found in this repo\'s '
            'Android build configuration. Locked-in product requirement 12 '
            'forbids any GMS dependency — Note Synapse must work on devices '
            'and ROMs without Play Services.\n'
            '${hits.join('\n')}',
      );
    });

    test('(B) pubspec.yaml declares no GMS-bearing package', () {
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue);
      final lines = const LineSplitter().convert(pubspec.readAsStringSync());

      final offenders = <String>[];
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        for (final pkg in kBannedPubPackages) {
          // Dependency keys appear as `  name:` at the start of the entry.
          if (RegExp('^$pkg\\s*:').hasMatch(trimmed)) {
            offenders.add('pubspec.yaml:${i + 1}  $trimmed');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Banned package(s) declared in pubspec.yaml. These pull Google '
            'Play Services onto Android (or, for flutter_appauth, are ruled '
            'out by M2.9\'s brief as unnecessary). The Drive OAuth flow is '
            'built from url_launcher + app_links + http + crypto only.\n'
            '${offenders.join('\n')}',
      );
    });

    test(
      '(C) no resolved Flutter plugin with an Android implementation names a '
      'GMS coordinate in its own Gradle files',
      () {
        final manifest = File('.flutter-plugins-dependencies');
        expect(
          manifest.existsSync(),
          isTrue,
          reason:
              '.flutter-plugins-dependencies is missing. It is generated by '
              '`flutter pub get`; without it this test cannot enumerate the '
              'resolved plugin set, and passing vacuously would be a false '
              'assurance. Run `flutter pub get` and re-run.',
        );

        final json =
            jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
        final androidPlugins =
            ((json['plugins'] as Map<String, dynamic>)['android'] as List)
                .cast<Map<String, dynamic>>();

        expect(
          androidPlugins,
          isNotEmpty,
          reason: 'No Android plugins resolved — scan would be vacuous.',
        );

        final hits = <_Hit>[];
        final scanned = <String>[];
        final missing = <String>[];

        for (final plugin in androidPlugins) {
          final name = plugin['name'] as String;
          final path = plugin['path'] as String?;
          if (path == null) continue;
          final androidDir = Directory('$path/android');
          if (!androidDir.existsSync()) {
            missing.add(name);
            continue;
          }
          scanned.add(name);
          for (final file in _gradleAndConfigFilesUnder(androidDir)) {
            hits.addAll(
              _scanFileForBannedTokens(file, label: '$name: ${file.path}'),
            );
          }
        }

        expect(
          scanned,
          isNotEmpty,
          reason:
              'None of the ${androidPlugins.length} resolved Android plugins '
              'had a readable android/ directory on this machine '
              '(missing: ${missing.join(', ')}). The scan would be vacuous; '
              'run `flutter pub get` so the pub cache is populated.',
        );

        expect(
          hits,
          isEmpty,
          reason:
              'A Flutter plugin this app depends on declares a Google Play '
              'Services / Firebase dependency. Locked-in product requirement '
              '12 forbids it. Scanned ${scanned.length} plugins '
              '(${androidPlugins.length} resolved).\n'
              '${hits.join('\n')}',
        );
      },
    );

    test('(D) the Drive OAuth implementation imports no auth SDK, only the '
        'already-approved packages', () {
      // A narrow but high-signal check on the specific files M2.9 added:
      // whatever else changes, THESE must never start importing an SDK.
      const files = [
        'lib/services/sync/google_drive_auth_service.dart',
        'lib/services/sync/google_drive_client_config.dart',
        'lib/services/sync/cloud_sync_service.dart',
        'lib/services/oauth_service.dart',
      ];
      const bannedImports = [
        'package:google_sign_in',
        'package:firebase_',
        'package:flutter_appauth',
        'package:googleapis_auth',
        'package:google_api_availability',
      ];

      final offenders = <String>[];
      for (final path in files) {
        final file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '$path is missing. If it was renamed, update this list — do '
              'not delete the check.',
        );
        final lines = const LineSplitter().convert(file.readAsStringSync());
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (!line.trimLeft().startsWith('import ')) continue;
          for (final banned in bannedImports) {
            if (line.contains(banned)) {
              offenders.add('$path:${i + 1}  ${line.trim()}');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'The Drive OAuth flow must stay plain HTTPS + custom URL '
            'scheme (url_launcher, app_links, http, crypto).\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
