import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide AndroidOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';

/// A single persisted cookie belonging to a saved web login session.
///
/// All scope-defining attributes (`domain`, `path`, `isSecure`, `isHttpOnly`,
/// `sameSite`) are captured verbatim so the cookie can be restored with exactly
/// the scope the site originally set. They are never widened or re-pointed at a
/// different domain — that is the core safeguard against leaking a cookie to an
/// unauthorized site.
class WebSessionCookie {
  const WebSessionCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.expiresDate,
    this.isSecure,
    this.isHttpOnly,
    this.sameSite,
  });

  final String name;
  final String value;
  final String? domain;
  final String? path;

  /// Expiry in milliseconds since epoch. `null` means a session cookie (no
  /// explicit expiry); such cookies are still restored.
  final int? expiresDate;
  final bool? isSecure;
  final bool? isHttpOnly;

  /// One of `Lax`, `Strict`, `None` (matching `HTTPCookieSameSitePolicy`).
  final String? sameSite;

  /// Whether the cookie has an explicit future expiry that is already in the
  /// past.
  ///
  /// A `null` expiry means a session cookie (no expiry). Some platforms report
  /// session cookies with a non-positive sentinel (`0` or `-1`) rather than
  /// `null`; those are treated as session cookies too, not as expired — so the
  /// auth cookie is still restored.
  bool get isExpired {
    final exp = expiresDate;
    if (exp == null || exp <= 0) {
      return false;
    }
    return DateTime.now().millisecondsSinceEpoch >= exp;
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    if (domain != null) 'domain': domain,
    if (path != null) 'path': path,
    if (expiresDate != null) 'expiresDate': expiresDate,
    if (isSecure != null) 'isSecure': isSecure,
    if (isHttpOnly != null) 'isHttpOnly': isHttpOnly,
    if (sameSite != null) 'sameSite': sameSite,
  };

  factory WebSessionCookie.fromJson(Map<String, dynamic> json) {
    return WebSessionCookie(
      name: json['name'] as String,
      value: json['value'] as String,
      domain: json['domain'] as String?,
      path: json['path'] as String?,
      expiresDate: (json['expiresDate'] as num?)?.toInt(),
      isSecure: json['isSecure'] as bool?,
      isHttpOnly: json['isHttpOnly'] as bool?,
      sameSite: json['sameSite'] as String?,
    );
  }
}

/// A saved login for a single registrable domain: the cookies captured after
/// the user logged in interactively, plus bookkeeping metadata.
class WebSession {
  const WebSession({
    required this.domain,
    required this.savedUrl,
    required this.savedAt,
    required this.cookies,
  });

  /// Registrable domain key this session is filed under (e.g. `example.com`).
  final String domain;

  /// The exact URL that was open when the session was captured.
  final String savedUrl;
  final DateTime savedAt;
  final List<WebSessionCookie> cookies;

  /// Cookies that are not expired and therefore worth restoring.
  List<WebSessionCookie> get liveCookies =>
      cookies.where((c) => !c.isExpired).toList();

  Map<String, dynamic> toJson() => {
    'domain': domain,
    'savedUrl': savedUrl,
    'savedAt': savedAt.toIso8601String(),
    'cookies': cookies.map((c) => c.toJson()).toList(),
  };

  factory WebSession.fromJson(Map<String, dynamic> json) {
    final rawCookies = (json['cookies'] as List?) ?? const [];
    return WebSession(
      domain: json['domain'] as String,
      savedUrl: (json['savedUrl'] as String?) ?? '',
      savedAt:
          DateTime.tryParse(json['savedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      cookies: rawCookies
          .map((c) => WebSessionCookie.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Abstracts reading and writing cookies in the platform [CookieManager] so the
/// service can be unit tested without a live WebView.
abstract class CookieGateway {
  Future<List<WebSessionCookie>> getCookies(String url);
  Future<void> setCookie(String url, WebSessionCookie cookie);
  Future<void> deleteCookies(String url);
}

/// Default [CookieGateway] backed by `flutter_inappwebview`'s [CookieManager].
class _InAppWebViewCookieGateway implements CookieGateway {
  CookieManager get _manager => CookieManager.instance();

  @override
  Future<List<WebSessionCookie>> getCookies(String url) async {
    final cookies = await _manager.getCookies(url: WebUri(url));
    return cookies.map((c) {
      return WebSessionCookie(
        name: c.name,
        value: c.value?.toString() ?? '',
        domain: c.domain,
        path: c.path,
        expiresDate: c.expiresDate,
        isSecure: c.isSecure,
        isHttpOnly: c.isHttpOnly,
        sameSite: c.sameSite?.toValue(),
      );
    }).toList();
  }

  @override
  Future<void> setCookie(String url, WebSessionCookie cookie) async {
    await _manager.setCookie(
      url: WebUri(url),
      name: cookie.name,
      value: cookie.value,
      // Replay the cookie's *own* captured scope. Never substitute the clip
      // target's domain/path here, or a cookie could be leaked to a site it
      // was not issued for.
      domain: cookie.domain,
      path: cookie.path ?? '/',
      expiresDate: cookie.expiresDate,
      isSecure: cookie.isSecure,
      isHttpOnly: cookie.isHttpOnly,
      sameSite: cookie.sameSite == null
          ? null
          : HTTPCookieSameSitePolicy.fromValue(cookie.sameSite),
    );
  }

  @override
  Future<void> deleteCookies(String url) async {
    await _manager.deleteCookies(url: WebUri(url));
  }
}

/// Abstracts the secure key/value backend so storage can be faked in tests and
/// so the Linux fallback (unencrypted [SharedPreferences]) lives in one place.
abstract class SessionStorageBackend {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Default backend: [FlutterSecureStorage] on Android/iOS/macOS, falling back to
/// [SharedPreferences] on Linux (and whenever secure storage throws). Mirrors
/// the pattern used by `OAuthTokenManager`.
class _SecureSessionStorageBackend implements SessionStorageBackend {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'note_synapse_secure',
      preferencesKeyPrefix: 'note_synapse_',
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static bool get _isLinux => !kIsWeb && Platform.isLinux;

  @override
  Future<void> write(String key, String value) async {
    if (_isLinux) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
      return;
    }
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  @override
  Future<String?> read(String key) async {
    if (_isLinux) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    }
    try {
      return await _storage.read(key: key);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    }
  }

  @override
  Future<void> delete(String key) async {
    if (_isLinux) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
      return;
    }
    try {
      await _storage.delete(key: key);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    }
  }
}

/// Persists and restores web login sessions (cookies) so authenticated pages
/// can be clipped.
///
/// Sessions live in secure storage rather than the database: cookies are
/// credentials, so they belong with the API key / OAuth tokens, and keeping
/// them out of the DB avoids a schema migration and a `recovery_screen.dart`
/// change.
///
/// ## Leak prevention
/// Each session is filed under the *registrable domain* of the site, and
/// [restoreCookies] only ever injects the single session matching the page
/// being clipped. Cookies are restored with their own captured scope. Beyond
/// that, the platform WebView enforces RFC 6265 send rules, so a cookie can
/// only ever be sent to a host that domain/path-matches it regardless of what
/// sits in the shared cookie store.
class WebSessionService {
  WebSessionService({CookieGateway? cookieGateway, SessionStorageBackend? storage})
    : _cookies = cookieGateway ?? _InAppWebViewCookieGateway(),
      _storage = storage ?? _SecureSessionStorageBackend();

  final CookieGateway _cookies;
  final SessionStorageBackend _storage;

  static const _sessionPrefix = 'web_session_';
  static const _indexKey = 'web_session_index';

  /// `true` on platforms where session capture/restore cannot work reliably.
  /// On web, httpOnly cookies (most session cookies) are unreadable.
  bool get isSupported => !kIsWeb;

  /// `true` where secure storage is unavailable and sessions are persisted
  /// unencrypted. Callers should surface a warning to the user.
  bool get isStorageInsecure => !kIsWeb && Platform.isLinux;

  // --------------------------------------------------------------------------
  // Domain handling
  // --------------------------------------------------------------------------

  /// A small set of multi-label public suffixes, enough to keep common
  /// `co.uk`-style hosts from collapsing unrelated sites into one bucket.
  ///
  /// This is intentionally a pragmatic subset rather than the full Public
  /// Suffix List; unknown suffixes fall back to the last two labels.
  static const Set<String> _multiLabelSuffixes = {
    'co.uk', 'org.uk', 'gov.uk', 'ac.uk', 'me.uk', 'ltd.uk', 'plc.uk',
    'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au', 'id.au',
    'co.nz', 'net.nz', 'org.nz', 'govt.nz',
    'com.cn', 'net.cn', 'org.cn', 'gov.cn', 'edu.cn',
    'co.jp', 'or.jp', 'ne.jp', 'go.jp', 'ac.jp',
    'com.br', 'net.br', 'org.br', 'gov.br',
    'co.in', 'net.in', 'org.in', 'gov.in',
    'com.sg', 'edu.sg', 'gov.sg',
    'com.hk', 'org.hk', 'gov.hk',
    'co.za', 'org.za',
    'com.tw', 'org.tw', 'gov.tw',
  };

  /// Computes the registrable domain (the key a session is filed under) for a
  /// host or URL. Returns an empty string if no host can be determined.
  ///
  /// Examples:
  ///   `https://a.b.example.com/x` -> `example.com`
  ///   `https://shop.example.co.uk` -> `example.co.uk`
  static String domainKeyFor(String urlOrHost) {
    var host = urlOrHost.trim().toLowerCase();
    final uri = Uri.tryParse(host);
    if (uri != null && uri.host.isNotEmpty) {
      host = uri.host;
    } else {
      // Strip any scheme/path remnants if parsing as a bare host failed.
      host = host.replaceFirst(RegExp(r'^[a-z]+://'), '').split('/').first;
    }
    host = host.split(':').first; // drop port
    // Trim leading/trailing dots: a trailing-dot FQDN (`example.com.`) is
    // equivalent to the dotless form and must map to the same key.
    host = host.replaceAll(RegExp(r'^\.+|\.+$'), '');
    if (host.isEmpty) {
      return '';
    }
    // IP addresses (v4) are used as-is.
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
      return host;
    }

    final labels = host.split('.');
    if (labels.length <= 2) {
      return host;
    }

    final lastTwo = labels.sublist(labels.length - 2).join('.');
    if (_multiLabelSuffixes.contains(lastTwo)) {
      // Registrable domain is the last three labels.
      return labels.sublist(labels.length - 3).join('.');
    }
    return lastTwo;
  }

  // --------------------------------------------------------------------------
  // Index management
  // --------------------------------------------------------------------------

  Future<List<String>> _readIndex() async {
    final raw = await _storage.read(_indexKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (e) {
      LoggerService.warning('WebSessionService: corrupt index, resetting: $e');
    }
    return [];
  }

  Future<void> _writeIndex(List<String> domains) async {
    await _storage.write(_indexKey, jsonEncode(domains));
  }

  Future<void> _addToIndex(String domain) async {
    final index = await _readIndex();
    if (!index.contains(domain)) {
      index.add(domain);
      await _writeIndex(index);
    }
  }

  Future<void> _removeFromIndex(String domain) async {
    final index = await _readIndex();
    if (index.remove(domain)) {
      await _writeIndex(index);
    }
  }

  // --------------------------------------------------------------------------
  // Public API
  // --------------------------------------------------------------------------

  /// Returns the registrable domains that currently have a saved session,
  /// sorted alphabetically.
  Future<List<String>> listDomains() async {
    final index = await _readIndex();
    index.sort();
    return index;
  }

  /// Loads the saved session for [domain], or `null` if none exists.
  Future<WebSession?> getSession(String domain) async {
    final raw = await _storage.read('$_sessionPrefix$domain');
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      return WebSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      LoggerService.warning(
        'WebSessionService: failed to decode session for domain: $e',
      );
      return null;
    }
  }

  /// Captures the current cookies for the site at [url] and persists them as a
  /// session, keyed by the URL's registrable domain.
  ///
  /// Reads cookies for both the exact host and the registrable domain so that
  /// host-only and domain-wide cookies are both captured. Returns the saved
  /// [WebSession], or `null` if no cookies could be read (e.g. not logged in,
  /// or the platform does not expose cookies).
  Future<WebSession?> saveSessionFromUrl(String url) async {
    if (!isSupported) {
      LoggerService.warning(
        'WebSessionService: session capture not supported on this platform',
      );
      return null;
    }
    final domain = domainKeyFor(url);
    if (domain.isEmpty) {
      throw ArgumentError('Could not determine domain for URL: $url');
    }

    final collected = <String, WebSessionCookie>{};
    Future<void> collect(String forUrl) async {
      try {
        for (final cookie in await _cookies.getCookies(forUrl)) {
          // Key by name+domain+path so host-only and domain-wide cookies with
          // the same name are not deduplicated against each other.
          collected['${cookie.name}|${cookie.domain}|${cookie.path}'] = cookie;
        }
      } catch (e) {
        LoggerService.warning('WebSessionService: getCookies failed: $e');
      }
    }

    await collect(url);
    await collect('https://$domain');

    if (collected.isEmpty) {
      LoggerService.debug(
        'WebSessionService: no cookies captured for $domain',
      );
      return null;
    }

    final session = WebSession(
      domain: domain,
      savedUrl: url,
      savedAt: DateTime.now(),
      cookies: collected.values.toList(),
    );

    await _storage.write(
      '$_sessionPrefix$domain',
      jsonEncode(session.toJson()),
    );
    await _addToIndex(domain);
    LoggerService.info(
      'WebSessionService: saved session for $domain (${session.cookies.length} cookies)',
    );
    return session;
  }

  /// Deletes the saved session for [domain] and clears the matching cookies
  /// from the live cookie store so the login is fully revoked.
  ///
  /// Clears cookies both at the registrable-domain URL (domain-wide cookies)
  /// and at the exact host the session was captured on (host-only cookies set
  /// on a subdomain), so a subdomain session cookie is not left behind.
  Future<void> deleteSession(String domain) async {
    // Read before deleting so we know the captured host for host-only cookies.
    final session = await getSession(domain);

    await _storage.delete('$_sessionPrefix$domain');
    await _removeFromIndex(domain);

    if (isSupported) {
      final urls = <String>{'https://$domain'};
      final savedHost = _hostUrlFor(session?.savedUrl);
      if (savedHost != null) {
        urls.add(savedHost);
      }
      for (final url in urls) {
        try {
          await _cookies.deleteCookies(url);
        } catch (e) {
          LoggerService.warning(
            'WebSessionService: failed to clear live cookies at $url: $e',
          );
        }
      }
    }
    LoggerService.info('WebSessionService: deleted session for $domain');
  }

  /// Returns an `https://host/` URL for the host of [url], or `null` if [url]
  /// is null/blank or has no host.
  static String? _hostUrlFor(String? url) {
    if (url == null || url.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    return 'https://${uri.host}';
  }

  /// Restores the saved session (if any) for the registrable domain of [url]
  /// into the live cookie store, so a subsequent navigation to [url] is
  /// authenticated.
  ///
  /// Only the single session matching [url]'s domain is injected — other saved
  /// sessions are never touched. Returns `true` if a live session was restored.
  Future<bool> restoreCookies(String url) async {
    if (!isSupported) {
      return false;
    }
    final domain = domainKeyFor(url);
    if (domain.isEmpty) {
      return false;
    }
    final session = await getSession(domain);
    if (session == null) {
      return false;
    }

    final live = session.liveCookies;
    if (live.isEmpty) {
      LoggerService.debug(
        'WebSessionService: session for $domain has only expired cookies',
      );
      return false;
    }

    // Host-only cookies (no Domain attribute) must be restored against the
    // exact host they were captured on, or the platform files them under the
    // bare registrable domain and they are not sent to the original subdomain.
    // Domain cookies are restored against the registrable-domain URL and carry
    // their own Domain attribute, so the platform scopes them correctly.
    final domainUrl = 'https://$domain';
    final hostUrl = _hostUrlFor(session.savedUrl) ?? domainUrl;

    var restored = 0;
    for (final cookie in live) {
      final isHostOnly = cookie.domain == null || cookie.domain!.isEmpty;
      final targetUrl = isHostOnly ? hostUrl : domainUrl;
      try {
        await _cookies.setCookie(targetUrl, cookie);
        restored++;
      } catch (e) {
        LoggerService.warning(
          'WebSessionService: failed to restore a cookie for $domain: $e',
        );
      }
    }
    LoggerService.info(
      'WebSessionService: restored $restored cookies for $domain',
    );
    return restored > 0;
  }
}
