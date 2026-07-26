import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';

/// Records which user apps the user has authorised to use a saved web-login
/// session for a given registrable domain.
///
/// A grant is the permission behind session-authenticated networking
/// (`proxyFetch({session: true})` and `Synapse.session.getCookies`): it lets an
/// app act as the user on a site the user logged into. Grants are keyed by the
/// app's `uuid` and the registrable domain (see
/// `WebSessionService.domainKeyFor`), and are created only through an explicit
/// approval prompt the first time an app requests access.
///
/// The store is deliberately small, non-secret bookkeeping (it holds no cookie
/// values — those stay in `WebSessionService`/secure storage), so it lives in
/// [SharedPreferences]. It is intentionally not persisted through
/// `recovery_screen.dart`: a grant is re-derivable trust that should be
/// re-confirmed rather than silently restored.
class AppDomainGrantService {
  AppDomainGrantService({SharedPreferences? prefs}) : _injectedPrefs = prefs;

  final SharedPreferences? _injectedPrefs;

  static const String _key = 'app_domain_grants';

  Future<SharedPreferences> get _prefs async =>
      _injectedPrefs ?? await SharedPreferences.getInstance();

  Future<Map<String, List<String>>> _read() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      return {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (appId, domains) => MapEntry(
            appId.toString(),
            (domains as List?)?.map((d) => d.toString()).toList() ?? <String>[],
          ),
        );
      }
    } catch (e) {
      LoggerService.warning('AppDomainGrantService: corrupt store, resetting: $e');
    }
    return {};
  }

  Future<void> _write(Map<String, List<String>> grants) async {
    final prefs = await _prefs;
    // Drop apps with no remaining domains so the store stays tidy.
    grants.removeWhere((_, domains) => domains.isEmpty);
    await prefs.setString(_key, jsonEncode(grants));
  }

  /// Whether [appUuid] may use the saved session for [domain].
  Future<bool> isGranted(String appUuid, String domain) async {
    final grants = await _read();
    return grants[appUuid]?.contains(domain) ?? false;
  }

  /// Grants [appUuid] access to [domain]'s saved session (idempotent).
  Future<void> grant(String appUuid, String domain) async {
    if (appUuid.isEmpty || domain.isEmpty) {
      return;
    }
    final grants = await _read();
    final domains = grants.putIfAbsent(appUuid, () => <String>[]);
    if (!domains.contains(domain)) {
      domains.add(domain);
      await _write(grants);
      LoggerService.info('AppDomainGrantService: granted $appUuid -> $domain');
    }
  }

  /// Revokes [appUuid]'s access to [domain] (idempotent).
  Future<void> revoke(String appUuid, String domain) async {
    final grants = await _read();
    if (grants[appUuid]?.remove(domain) ?? false) {
      await _write(grants);
      LoggerService.info('AppDomainGrantService: revoked $appUuid -> $domain');
    }
  }

  /// Removes every grant for [appUuid] (e.g. when the app is deleted).
  Future<void> revokeAllForApp(String appUuid) async {
    final grants = await _read();
    if (grants.remove(appUuid) != null) {
      await _write(grants);
    }
  }

  /// Removes every app's grant for [domain] (e.g. when the saved login for
  /// that domain is deleted).
  ///
  /// A grant is permission to act as the user on a specific credential, so it
  /// must not outlive that credential. Without this, deleting a saved login
  /// would leave the grant in place *and* invisible — the Web Logins screen
  /// lists grants under their saved login, so a grant whose login is gone has
  /// no row to be revoked from — and re-adding the login later would silently
  /// re-arm the app with no fresh approval prompt.
  Future<void> revokeAllForDomain(String domain) async {
    if (domain.isEmpty) {
      return;
    }
    final grants = await _read();
    var changed = false;
    for (final domains in grants.values) {
      if (domains.remove(domain)) {
        changed = true;
      }
    }
    if (changed) {
      // _write drops apps left with no domains, so the store stays tidy.
      await _write(grants);
      LoggerService.info(
        'AppDomainGrantService: revoked all grants for $domain',
      );
    }
  }

  /// The registrable domains [appUuid] is currently granted, sorted.
  Future<List<String>> domainsForApp(String appUuid) async {
    final grants = await _read();
    final domains = List<String>.from(grants[appUuid] ?? const []);
    domains.sort();
    return domains;
  }

  /// The app uuids currently granted access to [domain], sorted. Used by the
  /// Web Logins settings screen to show "used by" per saved login.
  Future<List<String>> appsForDomain(String domain) async {
    final grants = await _read();
    final apps = <String>[
      for (final entry in grants.entries)
        if (entry.value.contains(domain)) entry.key,
    ]..sort();
    return apps;
  }
}
