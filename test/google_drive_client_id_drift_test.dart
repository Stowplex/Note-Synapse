// M2.9 — permanent audit: the Google OAuth client ID compiled into Dart and
// the redirect scheme registered with the OS must never drift apart.
//
// **Why this test exists.** The OAuth redirect scheme is declared in four
// places that no compiler or build step cross-checks:
//
//   1. `lib/services/sync/google_drive_client_config.dart` — the client IDs
//      Dart sends to Google (`releaseClientId` / `debugClientId`), from
//      which the redirect URI is derived.
//   2. `android/app/build.gradle.kts` — `googleReversedClientIdRelease` /
//      `googleReversedClientIdDebug`, substituted into the manifest as
//      `${googleReversedClientId}`, which is what actually makes Android
//      route the redirect back to this app.
//   3. `ios/Flutter/Debug.xcconfig` / `Release.xcconfig` —
//      `GOOGLE_REVERSED_CLIENT_ID`, substituted into `Info.plist`'s
//      `CFBundleURLSchemes` for the same reason on iOS.
//   4. `android/app/src/main/AndroidManifest.xml` / `ios/Runner/Info.plist` —
//      the intent-filter / URL type that consumes those placeholders.
//
// If (1) and (2)/(3) disagree, the app asks Google to redirect to a scheme
// the OS has not registered for it. Nothing fails at build time, nothing
// fails at analysis time, and nothing fails when the user taps Connect —
// the browser opens, the user consents, and then the redirect goes nowhere:
// the app sits on the consent screen forever and eventually times out, with
// no diagnostic pointing at the mismatch. That is a genuinely hard bug to
// find from the symptom, and a trivial one to prevent from here.
//
// ============================================================================
// WHAT THIS TEST PROVES
// ============================================================================
//
// It proves that the *checked-in text* of the Gradle, xcconfig, manifest and
// Dart files is mutually consistent, and that the derivation rule
// ("reversed client ID") is applied identically in all of them. It also
// proves debug and release register DIFFERENT schemes (so two side-by-side
// installs cannot steal each other's authorization code) and that both
// placeholders are actually consumed by the platform config.
//
// It does NOT prove that either client ID is a real, working Google OAuth
// client, that its type/package/SHA-1 match this app, or that Google has
// the redirect URI registered — none of that is knowable without contacting
// Google with real credentials, which is a manual step by design.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/google_drive_client_config.dart';

/// Extracts `val <name> =` followed by a (possibly next-line) string literal
/// from a Kotlin Gradle script.
String? _kotlinVal(String source, String name) {
  final match = RegExp(
    'val\\s+$name\\s*=\\s*(?://[^\\n]*\\n\\s*)?"([^"]*)"',
  ).firstMatch(source);
  return match?.group(1);
}

/// Extracts `KEY=value` from an xcconfig file (ignoring comment lines).
String? _xcconfigValue(String source, String key) {
  for (final line in source.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('//')) continue;
    final match = RegExp('^$key\\s*=\\s*(.+)\$').firstMatch(trimmed);
    if (match != null) return match.group(1)!.trim();
  }
  return null;
}

String _read(String path) {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason:
        '$path is missing. If it moved, update this test — do not delete the '
        'check: it is the only thing keeping the Dart client ID and the '
        'OS-registered redirect scheme in agreement.',
  );
  return file.readAsStringSync();
}

void main() {
  group('Google Drive OAuth client ID / redirect scheme drift guard', () {
    late String gradle;
    late String manifest;
    late String debugXcconfig;
    late String releaseXcconfig;
    late String infoPlist;

    setUpAll(() {
      gradle = _read('android/app/build.gradle.kts');
      manifest = _read('android/app/src/main/AndroidManifest.xml');
      debugXcconfig = _read('ios/Flutter/Debug.xcconfig');
      releaseXcconfig = _read('ios/Flutter/Release.xcconfig');
      infoPlist = _read('ios/Runner/Info.plist');
    });

    test('the reversed-scheme derivation is what we think it is', () {
      // Guards the derivation itself, so a "cleanup" of reversedSchemeFor
      // cannot silently change every other assertion below in lockstep.
      expect(
        GoogleDriveClientConfig.reversedSchemeFor(
          '123456-abcdef.apps.googleusercontent.com',
        ),
        'com.googleusercontent.apps.123456-abcdef',
      );
      expect(GoogleDriveClientConfig.redirectPath, '/oauth2redirect');
      // Single colon + single slash, and the scheme is the current variant's.
      expect(
        GoogleDriveClientConfig.redirectUri,
        '${GoogleDriveClientConfig.redirectScheme}:/oauth2redirect',
      );
    });

    test('Gradle release scheme == reversed releaseClientId', () {
      final gradleRelease = _kotlinVal(gradle, 'googleReversedClientIdRelease');
      expect(
        gradleRelease,
        isNotNull,
        reason:
            '`val googleReversedClientIdRelease = "..."` not found in '
            'android/app/build.gradle.kts.',
      );
      expect(
        gradleRelease,
        GoogleDriveClientConfig.releaseRedirectScheme,
        reason:
            'Android release build registers a different OAuth redirect '
            'scheme than the release client ID in '
            'lib/services/sync/google_drive_client_config.dart implies. '
            'Google will redirect to '
            '"${GoogleDriveClientConfig.releaseRedirectScheme}'
            '${GoogleDriveClientConfig.redirectPath}", which this build does '
            'not handle, so consent would complete and then hang.',
      );
    });

    test('Gradle debug scheme == reversed debugClientId', () {
      final gradleDebug = _kotlinVal(gradle, 'googleReversedClientIdDebug');
      expect(gradleDebug, isNotNull);
      expect(
        gradleDebug,
        GoogleDriveClientConfig.debugRedirectScheme,
        reason:
            'Android debug build registers a different OAuth redirect scheme '
            'than debugClientId implies. If you just filled in a real debug '
            'client ID, update BOTH places.',
      );
    });

    test('debug and release register different schemes', () {
      // Requirement 4 of the M2.9 brief. `applicationIdSuffix = ".debug"`
      // means both variants can be installed at once; identical schemes
      // would let either app claim the other's redirect — including the
      // authorization code in its query string.
      expect(
        GoogleDriveClientConfig.debugRedirectScheme,
        isNot(GoogleDriveClientConfig.releaseRedirectScheme),
        reason:
            'Debug and release must not share an OAuth redirect scheme: both '
            'variants are installable side by side, and Android would let '
            'either one intercept the other\'s authorization code.',
      );
      expect(
        _kotlinVal(gradle, 'googleReversedClientIdDebug'),
        isNot(_kotlinVal(gradle, 'googleReversedClientIdRelease')),
      );
    });

    test('Gradle wires both placeholders and keeps the debug suffix', () {
      expect(
        gradle.contains(
          'manifestPlaceholders["googleReversedClientId"] = googleReversedClientIdDebug',
        ),
        isTrue,
        reason: 'The debug build type no longer sets the manifest placeholder.',
      );
      expect(
        gradle.contains(
          'manifestPlaceholders["googleReversedClientId"] = googleReversedClientIdRelease',
        ),
        isTrue,
        reason:
            'No build type / defaultConfig sets the release manifest '
            'placeholder. Without a defaultConfig fallback the `profile` '
            'variant fails manifest merging outright.',
      );
      expect(
        gradle.contains('applicationIdSuffix = ".debug"'),
        isTrue,
        reason:
            'The debug applicationIdSuffix is what makes debug a separate '
            'package, which is the entire reason two OAuth clients exist. If '
            'it is gone, the two-client setup needs rethinking.',
      );
    });

    test(
      'AndroidManifest consumes the placeholder and keeps MCP\'s scheme',
      () {
        expect(
          manifest.contains(r'android:scheme="${googleReversedClientId}"'),
          isTrue,
          reason:
              'AndroidManifest.xml no longer declares an intent-filter for the '
              'Drive OAuth redirect scheme, so the redirect cannot reach the '
              'app on Android.',
        );
        expect(
          manifest.contains('android:scheme="notesynapse"'),
          isTrue,
          reason:
              'The pre-existing MCP OAuth intent-filter (notesynapse://) is '
              'gone. M2.9 must not regress it.',
        );
      },
    );

    test('iOS xcconfigs match the Dart client IDs', () {
      expect(
        _xcconfigValue(debugXcconfig, 'GOOGLE_REVERSED_CLIENT_ID'),
        GoogleDriveClientConfig.debugRedirectScheme,
        reason:
            'ios/Flutter/Debug.xcconfig disagrees with debugClientId. iOS '
            'Debug builds would register a scheme Dart never redirects to.',
      );
      expect(
        _xcconfigValue(releaseXcconfig, 'GOOGLE_REVERSED_CLIENT_ID'),
        GoogleDriveClientConfig.releaseRedirectScheme,
        reason:
            'ios/Flutter/Release.xcconfig disagrees with releaseClientId. '
            'Note this file also backs the Profile configuration.',
      );
    });

    test(
      'Info.plist consumes the iOS build setting and keeps MCP\'s scheme',
      () {
        expect(
          infoPlist.contains(r'$(GOOGLE_REVERSED_CLIENT_ID)'),
          isTrue,
          reason:
              'ios/Runner/Info.plist no longer registers the Drive OAuth '
              'redirect scheme.',
        );
        expect(
          infoPlist.contains('<string>notesynapse</string>'),
          isTrue,
          reason: 'The pre-existing MCP OAuth URL scheme is gone.',
        );
      },
    );

    test('placeholder client IDs stay recognizable as placeholders, and a real '
        'one is recognized as configured', () {
      // Both variants now have distinct configured clients. Placeholders
      // remain recognizable by the marker for future build configurations.
      expect(
        GoogleDriveClientConfig.debugClientId.contains(
          GoogleDriveClientConfig.placeholderMarker,
        ),
        isFalse,
        reason:
            'The DEBUG client ID looks like a placeholder; connecting would '
            'be disabled.',
      );
      expect(
        GoogleDriveClientConfig.debugClientId.endsWith(
          GoogleDriveClientConfig.clientIdSuffix,
        ),
        isTrue,
      );
      expect(
        GoogleDriveClientConfig.releaseClientId.contains(
          GoogleDriveClientConfig.placeholderMarker,
        ),
        isFalse,
        reason:
            'The release client configured in Gradle must also be configured '
            'in Dart and the iOS release xcconfig.',
      );

      // `isConfigured` is what the UI's "not available in this build"
      // state and `assertConfigured()`'s error both hang off. Assert it
      // tracks the marker for the variant this test run is compiled as,
      // so the two can't diverge (e.g. someone "simplifying"
      // `isConfigured` to a null check that a placeholder string passes).
      expect(
        GoogleDriveClientConfig.isConfigured,
        !GoogleDriveClientConfig.clientId.contains(
          GoogleDriveClientConfig.placeholderMarker,
        ),
      );

      // And that assertConfigured() agrees with isConfigured in both
      // directions, since that is the only thing standing between an
      // unconfigured build and a silent no-op at the Connect button.
      if (GoogleDriveClientConfig.isConfigured) {
        expect(GoogleDriveClientConfig.assertConfigured, returnsNormally);
      } else {
        expect(
          GoogleDriveClientConfig.assertConfigured,
          throwsA(isA<GoogleDriveClientNotConfiguredException>()),
        );
      }
    });

    test('every scheme in play parses as a legal URI scheme', () {
      // A placeholder containing an underscore would produce a scheme
      // `Uri.parse` cannot represent, turning a clear "not configured" error
      // into a confusing parse failure elsewhere. Assert on the actual
      // redirect URIs, both variants.
      for (final scheme in [
        GoogleDriveClientConfig.releaseRedirectScheme,
        GoogleDriveClientConfig.debugRedirectScheme,
      ]) {
        // NOTE the colon: the redirect is `scheme:/path`. Building it by
        // hand here (rather than reusing redirectUri, which only covers the
        // *current* variant) is what lets this check cover both variants.
        final uri = Uri.parse(
          '$scheme:${GoogleDriveClientConfig.redirectPath}',
        );
        expect(
          uri.scheme,
          scheme.toLowerCase(),
          reason:
              '"$scheme" is not a legal URI scheme (RFC 3986 allows only '
              'ALPHA / DIGIT / "+" / "-" / "." after a leading letter — note '
              'that "_" is NOT allowed).',
        );
        expect(
          scheme,
          scheme.toLowerCase(),
          reason:
              'Android intent-filter scheme matching is CASE-SENSITIVE '
              '(unlike RFC 3986). An uppercase letter anywhere in the scheme '
              'means AndroidManifest.xml declares a scheme that no incoming '
              'URI will ever match, while everything else — including this '
              'test\'s other assertions — still looks fine.',
        );
        expect(uri.path, GoogleDriveClientConfig.redirectPath);
        expect(
          uri.host,
          isEmpty,
          reason:
              'The redirect must be scheme:/path with no authority — a single '
              'slash, not two. Two slashes would make "oauth2redirect" a host '
              'and break both the Google-side registration and the Dart-side '
              'match.',
        );
      }
    });
  });
}
