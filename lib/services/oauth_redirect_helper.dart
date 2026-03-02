import 'dart:io';

import 'package:flutter/foundation.dart';

/// Helper for determining which redirect URI should be used for OAuth flows
/// based on the current platform. Mobile platforms use a custom URL scheme so
/// that the browser can bring the app back to the foreground without requiring
/// a localhost HTTP server, which is unreliable on iOS when the app is
/// backgrounded. Desktop and other platforms continue to use the loopback
/// redirect.
class OAuthRedirectHelper {
  OAuthRedirectHelper._();

  /// Loopback redirect used on desktop-style platforms.
  static const String loopbackRedirectUri = 'http://127.0.0.1:51791/callback';

  /// Custom scheme name shared between Android and iOS.
  static const String _customScheme = 'notesynapse';

  /// Redirect URI used on mobile platforms via the custom scheme.
  static const String customSchemeRedirectUri =
      '$_customScheme://oauth/callback';

  static bool get usesCustomScheme => _supportsCustomScheme();

  /// Resolves the redirect URI that should actually be used at runtime.
  /// When running on mobile platforms the value is forced to the custom
  /// scheme redirect because the application is only registered to handle
  /// that scheme.
  static String resolve(String? configured) {
    final trimmed = configured?.trim() ?? '';

    if (_supportsCustomScheme()) {
      if (trimmed.isEmpty) {
        return customSchemeRedirectUri;
      }

      final parsed = Uri.tryParse(trimmed);
      if (parsed == null) {
        return customSchemeRedirectUri;
      }

      if (parsed.scheme == _customScheme) {
        return parsed.toString();
      }

      if (_isLoopback(parsed)) {
        return customSchemeRedirectUri;
      }

      // Google reverse-client-ID scheme — registered in AndroidManifest /
      // Info.plist; pass through as-is.
      if (parsed.scheme.startsWith('com.googleusercontent.apps.')) {
        return parsed.toString();
      }

      // Any other scheme is unsupported because the app is not registered to
      // handle it. Fall back to the known-good custom scheme.
      return customSchemeRedirectUri;
    }

    if (trimmed.isEmpty) {
      return loopbackRedirectUri;
    }

    return trimmed;
  }

  /// Returns the default redirect URI for the current platform.
  static String defaultForCurrentPlatform() => resolve(null);

  /// Returns true when [uri] matches the provided [redirectUri].
  static bool matchesRedirect(Uri uri, String redirectUri) {
    final expected = Uri.tryParse(redirectUri);
    if (expected == null) {
      return false;
    }

    if (expected.scheme != uri.scheme) {
      return false;
    }

    if ((expected.host.isEmpty ? null : expected.host) !=
        (uri.host.isEmpty ? null : uri.host)) {
      return false;
    }

    final expectedPath = expected.path.isEmpty ? '/' : expected.path;
    final actualPath = uri.path.isEmpty ? '/' : uri.path;
    return expectedPath == actualPath;
  }

  static bool _supportsCustomScheme() {
    if (kIsWeb) {
      return false;
    }
    try {
      return Platform.isIOS || Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  static bool _isLoopback(Uri uri) {
    if (!uri.hasAuthority) {
      return false;
    }
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost';
  }
}
