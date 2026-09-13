// Google OAuth client configuration for Drive sync — M2.9.
//
// ===========================================================================
// READ THIS FIRST: both clients must be of the **iOS** application type.
// ===========================================================================
//
// Not Android. Not Desktop. This is counter-intuitive for an app whose two
// variants are distinguished by *Android* package name, so it is spelled out
// rather than left to be inferred:
//
//   * The redirect this whole milestone registers —
//     `com.googleusercontent.apps.<prefix>:/oauth2redirect`, the "reversed
//     client ID" — is the **iOS** client pattern. An **Android**-type client
//     does not get one: its private-use redirect is
//     `<package.name>:/oauth2redirect` instead. Creating an Android-type
//     client and pasting its ID below therefore produces a client that
//     *cannot* use the redirect this app registers with the OS, and Google
//     rejects the authorization request (`redirect_uri_mismatch`).
//   * Google's native-app documentation is now titled "OAuth 2.0 for **iOS
//     & Desktop Apps**" — Android was removed from it — and Google has
//     restricted custom URI schemes for *new* Android OAuth clients
//     outright. So iOS-type is not merely the tidier choice here; for a
//     custom-scheme flow it is the only one still available.
//     - https://developers.google.com/identity/protocols/oauth2/native-app
//     - https://developers.googleblog.com/improving-user-safety-in-oauth-flows-through-new-oauth-custom-uri-scheme-restrictions/
//   * Desktop type is separately ruled out: it issues a client secret, and
//     Note Synapse is open source, so anything in the binary is public.
//     iOS-type clients issue no secret and rely on PKCE (RFC 7636), which is
//     what `GoogleDriveAuthService` uses.
//
// An iOS-type client is bound to a **bundle ID** and carries no SHA-1
// fingerprint. Google does not refuse to serve it to an Android device — the
// binding that actually matters for this flow is the redirect scheme, which
// only the app registering that scheme can receive. That is why one client
// type covers both platforms here.
//
// **Nothing below has been verified against Google.** See [releaseClientId].
//
// **Why there are two client IDs, and why they must not be merged.**
// `android/app/build.gradle.kts` gives the debug build type
// `applicationIdSuffix = ".debug"`, so a debug install is the *separate
// Android package* `com.github.kkspeed.note_synapse.note_synapse.debug`,
// installable side by side with a release install. Two installs on one
// device must not register the same custom URL scheme: if they did, Android
// would show a disambiguation chooser (or silently hand the redirect to
// whichever app the system picked) and one build could swallow the other
// build's OAuth callback, authorization code included.
//
// Note what this reasoning does *not* rest on: it is NOT that an OAuth
// client is bound to an Android package name (iOS-type clients are not —
// they have no package name and no SHA-1). Two clients exist purely because
// two clients are the only way to obtain two *distinct reversed-client-ID
// schemes*, and distinct schemes are what keep the two installs apart. Any
// two iOS-type clients will do; their bundle IDs are not load-bearing for
// this flow.
//
// **Why the redirect is the reversed client ID.** Google deprecated the
// loopback (`http://127.0.0.1:port`) redirect for mobile client types
// (blocked for new clients since Oct 2022), and on iOS a loopback listener
// can be suspended by the OS during the foreground handoff to the browser,
// so the redirect may never land. The OAuth 2.0 device flow is not an
// option either: Drive scopes are not in Google's device-flow allowlist.
// That leaves the private-use URI scheme, which for Google is the client ID
// reversed: `com.googleusercontent.apps.<prefix>:/oauth2redirect`.
//
// **Single source of truth.** The scheme is *derived* here from the client
// ID ([reversedSchemeFor]) rather than written out a second time, so the
// only way Dart and Gradle can disagree is if the Gradle literal itself
// drifts — which `test/google_drive_client_id_drift_test.dart` fails on.
// That test compares strings this repo controls; it can say nothing about
// what Google has on file for either client (see [releaseClientId]).

import 'package:flutter/foundation.dart';

/// Thrown when a Drive OAuth flow is started before a real client ID has
/// been configured for the running build variant. Carries a message written
/// for the person who has to fix it (the developer running a debug build),
/// because that is who will see it.
class GoogleDriveClientNotConfiguredException implements Exception {
  const GoogleDriveClientNotConfiguredException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Per-build-variant Google OAuth client configuration.
class GoogleDriveClientConfig {
  GoogleDriveClientConfig._();

  /// Suffix every Google OAuth client ID carries.
  static const String clientIdSuffix = '.apps.googleusercontent.com';

  /// Prefix of every Google private-use redirect scheme.
  static const String reversedSchemePrefix = 'com.googleusercontent.apps.';

  /// The path component Google's own documentation uses for the
  /// private-use-scheme redirect. Note the SINGLE slash: the redirect is
  /// `scheme:/oauth2redirect`, not `scheme://oauth2redirect` — the scheme
  /// is followed by a path, not an authority. Registered in Google Cloud
  /// Console exactly as written here.
  static const String redirectPath = '/oauth2redirect';

  /// Client ID used by release and profile builds, matching the release
  /// client configured in android/app/build.gradle.kts. Keep its reversed
  /// scheme in ios/Flutter/Release.xcconfig consistent too.
  ///
  /// Repository tests verify these settings agree; the Google-side client
  /// type and redirect registration still require a real authorization flow.
  static const String releaseClientId =
      '438894533578-g0tpgg76soku9srh76hj21p14to3kc4c$clientIdSuffix';

  /// Client ID used by debug builds. Its redirect scheme stays distinct
  /// from release so side-by-side Android installations receive their own
  /// authorization callbacks. Keep android/app/build.gradle.kts and
  /// ios/Flutter/Debug.xcconfig aligned when replacing it.
  static const String debugClientId =
      '438894533578-i9ecrp6g518tdenpq5fo4dkv90ce2rig$clientIdSuffix';

  /// The token every unconfigured placeholder client ID starts with.
  ///
  /// Two spelling constraints, both load-bearing rather than stylistic,
  /// because this string ends up verbatim inside a URL scheme (see
  /// [reversedSchemeFor]) that Android and iOS must both match:
  ///
  ///  * **Hyphens, not underscores.** RFC 3986's scheme grammar is
  ///    `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` — `_` is not in it, so
  ///    an underscored placeholder would produce a scheme `Uri.parse`
  ///    cannot represent, turning a clear "not configured yet" error into a
  ///    confusing parse failure further downstream.
  ///  * **Lowercase.** Android's intent-filter scheme matching is
  ///    case-sensitive (unlike the RFC), so a scheme containing uppercase
  ///    letters in `AndroidManifest.xml` would never match an incoming
  ///    URI — Dart's own `Uri.parse` lowercases `scheme`, and the browser
  ///    hands Android the URI as written. Real Google client IDs are
  ///    already lowercase; keeping the placeholder lowercase means the
  ///    placeholder behaves like the real thing.
  static const String placeholderMarker = 'replace-with-';

  /// The client ID for the running build variant.
  static String get clientId => kDebugMode ? debugClientId : releaseClientId;

  /// False while [clientId] is still the checked-in placeholder.
  static bool get isConfigured => !clientId.contains(placeholderMarker);

  /// Converts a Google client ID into its private-use ("reversed") URL
  /// scheme: `<prefix>.apps.googleusercontent.com` ->
  /// `com.googleusercontent.apps.<prefix>`.
  static String reversedSchemeFor(String clientId) {
    final prefix = clientId.endsWith(clientIdSuffix)
        ? clientId.substring(0, clientId.length - clientIdSuffix.length)
        : clientId;
    return '$reversedSchemePrefix$prefix';
  }

  /// The custom URL scheme this build registers with the OS (Android
  /// manifest placeholder `googleReversedClientId`, iOS
  /// `GOOGLE_REVERSED_CLIENT_ID`).
  static String get redirectScheme => reversedSchemeFor(clientId);

  /// The full redirect URI handed to Google and matched against the
  /// incoming deep link.
  static String get redirectUri => '$redirectScheme:$redirectPath';

  /// Scheme/redirect for a specific variant — used by the drift test (which
  /// must check both variants regardless of which one it is itself running
  /// under) and by nothing in production code.
  @visibleForTesting
  static String get releaseRedirectScheme => reversedSchemeFor(releaseClientId);

  @visibleForTesting
  static String get debugRedirectScheme => reversedSchemeFor(debugClientId);

  /// Throws [GoogleDriveClientNotConfiguredException] if this build variant
  /// still carries a placeholder client ID.
  ///
  /// Called at the top of `GoogleDriveAuthService.connect()`. Note that the
  /// settings screen does not render a Connect button in the
  /// `notConfigured` state (see [debugClientId]), so in practice this fires
  /// for tests and any future programmatic caller rather than for a user
  /// tap — it is the guard that keeps "the UI happens not to offer it"
  /// from being the only thing preventing a broken consent attempt.
  static void assertConfigured() {
    if (isConfigured) return;
    throw GoogleDriveClientNotConfiguredException(
      'No Google OAuth client ID is configured for this '
      '${kDebugMode ? 'debug' : 'release'} build. '
      'Set ${kDebugMode ? 'debugClientId' : 'releaseClientId'} in '
      'lib/services/sync/google_drive_client_config.dart and the matching '
      '${kDebugMode ? 'googleReversedClientIdDebug' : 'googleReversedClientIdRelease'} '
      'value in android/app/build.gradle.kts (see that constant\'s doc '
      'comment for the exact steps), then reinstall the app so the new '
      'redirect scheme is registered with the OS.',
    );
  }
}
