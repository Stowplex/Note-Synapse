import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

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

  // Cached at app startup via initialize(). Falls back to 'notesynapse' if
  // initialize() hasn't been called yet.
  static String? _cachedScheme;

  static String get _customScheme => _cachedScheme ?? 'notesynapse';

  /// Redirect URI used on mobile platforms via the package-name scheme.
  /// Format: `<scheme>:/oauthcallback`  (single slash, no host)
  static String get customSchemeRedirectUri => '$_customScheme:/oauthcallback';

  /// Must be called once during app startup (before any OAuth flow).
  static Future<void> initialize() async {
    if (_supportsCustomScheme()) {
      final info = await PackageInfo.fromPlatform();
      _cachedScheme = info.packageName;
    }
  }

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
