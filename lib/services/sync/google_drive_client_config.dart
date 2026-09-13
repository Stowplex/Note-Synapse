// Google OAuth client configuration for Drive sync.
//
// Dart selects a separate client for debug versus release/profile builds.
// Android manifest placeholders and iOS xcconfigs must register the same
// callback scheme that Dart sends; google_drive_client_id_drift_test.dart
// checks that contract. Distinct debug/release callbacks keep side-by-side
// Android installations from receiving each other's authorization response.
//
// The release ID was verified against the supplied installed-client JSON.
// An unauthenticated authorization probe on 2026-09-12 identified this as an
// Android client and returned: "Custom URI scheme is not enabled for your
// Android client." The owner subsequently confirmed the custom-scheme opt-in
// is enabled. Retain browser + PKCE; that configuration action is complete.
// The probe has not been rerun, and signed-device consent/refresh/Drive access
// still need verification. Google recommends Identity Services
// AuthorizationClient for Android Drive authorization, but it requires GMS.
// https://support.google.com/googleapi/answer/6158849
// https://developer.android.com/identity/authorization
//
// This implementation currently uses a system browser, PKCE and a private-use
// callback to satisfy the no-GMS requirement recorded in GoogleDriveAuthService
// and test/no_gms_dependency_audit_test.dart. Google's custom-scheme opt-in is
// an exception for apps that cannot use the recommended API, not the default
// release recommendation: custom schemes permit app impersonation. Do not
// infer client type or permissions from the JSON's "installed" key or filename.
// https://developers.googleblog.com/improving-user-safety-in-oauth-flows-through-new-oauth-custom-uri-scheme-restrictions/
//
// Client IDs are public identifiers; no client secret belongs in the app.
// Matching repository/build settings proves callback wiring, not Google-side
// authorization. Validate the client registration and complete a real
// authorization flow for each shipping platform. iOS needs its own iOS client;
// copying the Android client's callback into iOS settings does not provide one.

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
