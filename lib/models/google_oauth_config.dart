import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';

/// Google Cloud Console Client ID for Desktop (loopback redirect).
/// This is a public identifier — safe to embed. No client secret is used.
/// OAuth security is provided by PKCE (S256 code challenge).
///
/// To register your own: https://console.cloud.google.com/
/// Create a project → APIs & Services → Credentials → Create OAuth client ID
/// → Application type: Desktop app
const _kGoogleClientIdDesktop =
    '438894533578-i9ecrp6g518tdenpq5fo4dkv90ce2rig.apps.googleusercontent.com';

/// Android debug OAuth client ID (Android app type, SHA-1 of debug keystore).
const _kGoogleClientIdAndroidDebug =
    '438894533578-i9ecrp6g518tdenpq5fo4dkv90ce2rig.apps.googleusercontent.com';

/// Android release OAuth client ID.
/// TODO: replace with the Android release client ID from Google Cloud Console.
const _kGoogleClientIdAndroidRelease =
    'TODO_ANDROID_RELEASE_CLIENT_ID.apps.googleusercontent.com';

/// iOS OAuth client ID (iOS app type).
const _kGoogleClientIdIos =
    '438894533578-8kakjr1bfmeg61hkc566pkjg0si5nb4h.apps.googleusercontent.com';

/// Builds the reverse-client-ID redirect URI required by Google's Android/iOS
/// OAuth clients: `com.googleusercontent.apps.{PREFIX}:/oauth2redirect`
String _googleRedirectUri(String clientId) {
  // clientId format: "{prefix}.apps.googleusercontent.com"
  final prefix = clientId.split('.apps.googleusercontent.com').first;
  return 'com.googleusercontent.apps.$prefix:/oauth2redirect';
}

/// Returns the OAuth 2.0 configuration for Google Drive access, selecting the
/// appropriate client ID and redirect URI for the current platform.
///
/// Uses the drive.file scope (access only to files created by this app),
/// PKCE for security (no client secret needed for public clients),
/// and a redirect URI resolved at runtime by [OAuthRedirectHelper].
OAuthConfig googleDriveOAuthConfig() {
  if (!kIsWeb && Platform.isAndroid) {
    final clientId =
        kDebugMode ? _kGoogleClientIdAndroidDebug : _kGoogleClientIdAndroidRelease;
    return OAuthConfig(
      authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
      tokenEndpoint: 'https://oauth2.googleapis.com/token',
      clientId: clientId,
      clientSecret: null,
      scope: 'https://www.googleapis.com/auth/drive.file',
      usePkce: true,
      redirectUri: _googleRedirectUri(clientId),
    );
  } else if (!kIsWeb && Platform.isIOS) {
    return OAuthConfig(
      authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
      tokenEndpoint: 'https://oauth2.googleapis.com/token',
      clientId: _kGoogleClientIdIos,
      clientSecret: null,
      scope: 'https://www.googleapis.com/auth/drive.file',
      usePkce: true,
      redirectUri: _googleRedirectUri(_kGoogleClientIdIos),
    );
  }
  // Desktop: empty redirectUri resolved to loopback by OAuthRedirectHelper.
  return OAuthConfig(
    authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenEndpoint: 'https://oauth2.googleapis.com/token',
    clientId: _kGoogleClientIdDesktop,
    clientSecret: null,
    scope: 'https://www.googleapis.com/auth/drive.file',
    usePkce: true,
    redirectUri: '',
  );
}
