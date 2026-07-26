import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/app_domain_grant_service.dart';
import 'package:note_synapse/services/web_session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory [SessionStorageBackend] for tests.
class _FakeStorage implements SessionStorageBackend {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

/// In-memory [CookieGateway] for tests. Stores cookies keyed by registrable
/// domain and records the restore (setCookie) and delete calls.
class _FakeCookieGateway implements CookieGateway {
  /// Cookies that `getCookies` should return, keyed by exact request URL.
  final Map<String, List<WebSessionCookie>> available = {};

  /// Cookies that were restored via setCookie, paired with the target URL.
  final List<({String url, WebSessionCookie cookie})> restored = [];

  /// URLs passed to deleteCookies.
  final List<String> deleted = [];

  @override
  Future<List<WebSessionCookie>> getCookies(String url) async {
    return available[url] ?? const [];
  }

  @override
  Future<void> setCookie(String url, WebSessionCookie cookie) async {
    restored.add((url: url, cookie: cookie));
  }

  @override
  Future<void> deleteCookies(String url) async {
    deleted.add(url);
  }
}

void main() {
  // SharedPreferences (used by AppDomainGrantService in the delete tests)
  // needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebSessionCookie serialization', () {
    test('round-trips through JSON', () {
      const cookie = WebSessionCookie(
        name: 'session',
        value: 'abc123',
        domain: '.example.com',
        path: '/',
        expiresDate: 1800000000000,
        isSecure: true,
        isHttpOnly: true,
        sameSite: 'Lax',
      );

      final decoded = WebSessionCookie.fromJson(cookie.toJson());

      expect(decoded.name, 'session');
      expect(decoded.value, 'abc123');
      expect(decoded.domain, '.example.com');
      expect(decoded.path, '/');
      expect(decoded.expiresDate, 1800000000000);
      expect(decoded.isSecure, true);
      expect(decoded.isHttpOnly, true);
      expect(decoded.sameSite, 'Lax');
    });

    test('omits null optional fields and tolerates them on decode', () {
      const cookie = WebSessionCookie(name: 'n', value: 'v');
      final json = cookie.toJson();
      expect(json.containsKey('domain'), false);
      expect(json.containsKey('expiresDate'), false);

      final decoded = WebSessionCookie.fromJson(json);
      expect(decoded.domain, isNull);
      expect(decoded.isExpired, false);
    });

    test('isExpired reflects expiresDate', () {
      final past = WebSessionCookie(
        name: 'n',
        value: 'v',
        expiresDate: DateTime.now()
            .subtract(const Duration(days: 1))
            .millisecondsSinceEpoch,
      );
      final future = WebSessionCookie(
        name: 'n',
        value: 'v',
        expiresDate: DateTime.now()
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch,
      );
      expect(past.isExpired, true);
      expect(future.isExpired, false);
    });

    test('non-positive expiresDate sentinels are treated as session cookies', () {
      // Some platforms report session cookies with 0 or -1 instead of null.
      expect(
        const WebSessionCookie(name: 'n', value: 'v', expiresDate: 0).isExpired,
        false,
      );
      expect(
        const WebSessionCookie(name: 'n', value: 'v', expiresDate: -1).isExpired,
        false,
      );
    });
  });

  group('WebSession serialization', () {
    test('round-trips through JSON', () {
      final session = WebSession(
        domain: 'example.com',
        savedUrl: 'https://example.com/account',
        savedAt: DateTime.parse('2026-01-02T03:04:05.000'),
        cookies: const [
          WebSessionCookie(name: 'a', value: '1'),
          WebSessionCookie(name: 'b', value: '2'),
        ],
      );

      final decoded = WebSession.fromJson(session.toJson());
      expect(decoded.domain, 'example.com');
      expect(decoded.savedUrl, 'https://example.com/account');
      expect(decoded.savedAt, DateTime.parse('2026-01-02T03:04:05.000'));
      expect(decoded.cookies.length, 2);
      expect(decoded.cookies.first.name, 'a');
    });

    test('liveCookies excludes expired cookies', () {
      final session = WebSession(
        domain: 'example.com',
        savedUrl: 'https://example.com',
        savedAt: DateTime.now(),
        cookies: [
          const WebSessionCookie(name: 'live', value: '1'),
          WebSessionCookie(
            name: 'dead',
            value: '2',
            expiresDate: DateTime.now()
                .subtract(const Duration(days: 1))
                .millisecondsSinceEpoch,
          ),
        ],
      );
      expect(session.liveCookies.map((c) => c.name), ['live']);
    });
  });

  group('domainKeyFor', () {
    test('extracts registrable domain from deep subdomains', () {
      expect(
        WebSessionService.domainKeyFor('https://a.b.example.com/x?y=1'),
        'example.com',
      );
    });

    test('handles bare host without scheme', () {
      expect(WebSessionService.domainKeyFor('www.example.com'), 'example.com');
    });

    test('handles multi-label public suffixes', () {
      expect(
        WebSessionService.domainKeyFor('https://shop.example.co.uk'),
        'example.co.uk',
      );
      // Unrelated sites under the same suffix do NOT collapse together.
      expect(
        WebSessionService.domainKeyFor('https://a.co.uk'),
        isNot(WebSessionService.domainKeyFor('https://b.co.uk')),
      );
    });

    test('passes through bare two-label domains and IPs', () {
      expect(WebSessionService.domainKeyFor('example.com'), 'example.com');
      expect(
        WebSessionService.domainKeyFor('http://192.168.1.5:8080/x'),
        '192.168.1.5',
      );
    });

    test('strips leading dot and port', () {
      expect(WebSessionService.domainKeyFor('.example.com:443'), 'example.com');
    });

    test('trailing-dot FQDN maps to the same key as the dotless form', () {
      expect(
        WebSessionService.domainKeyFor('https://www.example.com.'),
        'example.com',
      );
    });
  });

  group('save / list / delete', () {
    late _FakeStorage storage;
    late _FakeCookieGateway cookies;
    late WebSessionService service;

    setUp(() {
      // deleteSession cascades into AppDomainGrantService, which is backed by
      // SharedPreferences even when this group does not assert on grants.
      SharedPreferences.setMockInitialValues({});
      storage = _FakeStorage();
      cookies = _FakeCookieGateway();
      service = WebSessionService(cookieGateway: cookies, storage: storage);
    });

    test('saveSessionFromUrl persists cookies and updates the index', () async {
      cookies.available['https://app.example.com/dashboard'] = const [
        WebSessionCookie(name: 'sid', value: 'xyz', domain: '.example.com'),
      ];

      final session = await service.saveSessionFromUrl(
        'https://app.example.com/dashboard',
      );

      expect(session, isNotNull);
      expect(session!.domain, 'example.com');
      expect(await service.listDomains(), ['example.com']);

      final loaded = await service.getSession('example.com');
      expect(loaded, isNotNull);
      expect(loaded!.cookies.single.name, 'sid');
    });

    test('saveSessionFromUrl returns null when no cookies exist', () async {
      final session = await service.saveSessionFromUrl('https://empty.com');
      expect(session, isNull);
      expect(await service.listDomains(), isEmpty);
    });

    test('deleteSession removes storage, index, and live cookies', () async {
      cookies.available['https://example.com'] = const [
        WebSessionCookie(name: 'sid', value: 'xyz'),
      ];
      await service.saveSessionFromUrl('https://example.com');
      expect(await service.listDomains(), ['example.com']);

      await service.deleteSession('example.com');

      expect(await service.listDomains(), isEmpty);
      expect(await service.getSession('example.com'), isNull);
      expect(cookies.deleted, contains('https://example.com'));
    });

    test('deleteSession revokes app grants for that domain', () async {
      final grants = AppDomainGrantService(
        prefs: await SharedPreferences.getInstance(),
      );
      await grants.grant('app1', 'example.com');
      await grants.grant('app1', 'other.com');
      final scoped = WebSessionService(
        cookieGateway: cookies,
        storage: storage,
        grantService: grants,
      );
      cookies.available['https://example.com'] = const [
        WebSessionCookie(name: 'sid', value: 'xyz'),
      ];
      await scoped.saveSessionFromUrl('https://example.com');

      await scoped.deleteSession('example.com');

      // A grant must not outlive the credential it was granted against, or
      // re-adding the login would silently re-arm the app.
      expect(await grants.isGranted('app1', 'example.com'), false);
      // Grants on unrelated domains survive.
      expect(await grants.isGranted('app1', 'other.com'), true);
    });

    test('listDomains returns sorted domains', () async {
      cookies.available['https://b.com'] = const [
        WebSessionCookie(name: 's', value: '1'),
      ];
      cookies.available['https://a.com'] = const [
        WebSessionCookie(name: 's', value: '1'),
      ];
      await service.saveSessionFromUrl('https://b.com');
      await service.saveSessionFromUrl('https://a.com');
      expect(await service.listDomains(), ['a.com', 'b.com']);
    });
  });

  group('restoreCookies', () {
    late _FakeStorage storage;
    late _FakeCookieGateway cookies;
    late WebSessionService service;

    setUp(() {
      storage = _FakeStorage();
      cookies = _FakeCookieGateway();
      service = WebSessionService(cookieGateway: cookies, storage: storage);
    });

    test('restores only live cookies for the matching domain', () async {
      // Seed a saved session directly with one live and one expired cookie.
      cookies.available['https://example.com'] = [
        const WebSessionCookie(name: 'live', value: '1', domain: '.example.com'),
        WebSessionCookie(
          name: 'dead',
          value: '2',
          expiresDate: DateTime.now()
              .subtract(const Duration(days: 1))
              .millisecondsSinceEpoch,
        ),
      ];
      await service.saveSessionFromUrl('https://example.com');

      final restored = await service.restoreCookies(
        'https://app.example.com/page',
      );

      expect(restored, true);
      expect(cookies.restored.length, 1);
      expect(cookies.restored.single.cookie.name, 'live');
      // Cookie is restored carrying its own captured domain, not re-scoped.
      expect(cookies.restored.single.cookie.domain, '.example.com');
    });

    test('host-only cookies are restored against their captured host', () async {
      // A host-only cookie (no domain) captured at app.example.com must be
      // re-injected against that host, not the bare registrable domain.
      cookies.available['https://app.example.com/dashboard'] = const [
        WebSessionCookie(name: 'sid', value: 'x'), // domain == null
      ];
      await service.saveSessionFromUrl('https://app.example.com/dashboard');

      final restored = await service.restoreCookies(
        'https://app.example.com/page',
      );

      expect(restored, true);
      expect(cookies.restored.single.url, 'https://app.example.com');
    });

    test('domain cookies are restored against the registrable domain', () async {
      cookies.available['https://app.example.com/dashboard'] = const [
        WebSessionCookie(name: 'sid', value: 'x', domain: '.example.com'),
      ];
      await service.saveSessionFromUrl('https://app.example.com/dashboard');

      await service.restoreCookies('https://app.example.com/page');

      expect(cookies.restored.single.url, 'https://example.com');
    });

    test('returns false when no session exists for the domain', () async {
      final restored = await service.restoreCookies('https://nothing.com');
      expect(restored, false);
      expect(cookies.restored, isEmpty);
    });

    test('does not restore sessions belonging to other domains', () async {
      cookies.available['https://other.com'] = const [
        WebSessionCookie(name: 's', value: '1', domain: '.other.com'),
      ];
      await service.saveSessionFromUrl('https://other.com');

      final restored = await service.restoreCookies('https://example.com');
      expect(restored, false);
      expect(cookies.restored, isEmpty);
    });
  });

  group('cookieHeaderFor', () {
    late _FakeStorage storage;
    late _FakeCookieGateway cookies;
    late WebSessionService service;

    setUp(() {
      storage = _FakeStorage();
      cookies = _FakeCookieGateway();
      service = WebSessionService(cookieGateway: cookies, storage: storage);
    });

    Future<void> saveSession(
      String url,
      List<WebSessionCookie> sessionCookies,
    ) async {
      cookies.available[url] = sessionCookies;
      await service.saveSessionFromUrl(url);
    }

    test('returns empty string when there is no saved session', () async {
      expect(await service.cookieHeaderFor('https://example.com/x'), '');
    });

    test('joins matching cookies as name=value pairs', () async {
      await saveSession('https://app.example.com/', const [
        WebSessionCookie(name: 'sid', value: 'abc', domain: '.example.com'),
        WebSessionCookie(name: 'csrf', value: 'xyz', domain: '.example.com'),
      ]);

      final header = await service.cookieHeaderFor('https://app.example.com/api');
      expect(header.split('; ')..sort(), ['csrf=xyz', 'sid=abc']);
    });

    test('omits Secure cookies for http requests', () async {
      await saveSession('https://example.com/', const [
        WebSessionCookie(
          name: 'sec',
          value: '1',
          domain: '.example.com',
          isSecure: true,
        ),
        WebSessionCookie(name: 'plain', value: '2', domain: '.example.com'),
      ]);

      expect(await service.cookieHeaderFor('http://example.com/'), 'plain=2');
      final https = await service.cookieHeaderFor('https://example.com/');
      expect(https.contains('sec=1'), true);
    });

    test('excludes cookies whose path does not match the request', () async {
      await saveSession('https://example.com/', const [
        WebSessionCookie(
          name: 'scoped',
          value: 'v',
          domain: '.example.com',
          path: '/admin',
        ),
      ]);

      expect(await service.cookieHeaderFor('https://example.com/public'), '');
      expect(
        await service.cookieHeaderFor('https://example.com/admin/x'),
        'scoped=v',
      );
    });

    test('liveCookieHeaderFor merges host + registrable-domain live cookies',
        () async {
      // The live jar returns host-scoped cookies for the exact URL and the
      // registrable-domain read pulls the domain-wide auth cookies.
      cookies.available['https://lh3.example.com/media?x=1'] = const [
        WebSessionCookie(name: 'HOSTC', value: 'h'),
      ];
      cookies.available['https://example.com'] = const [
        WebSessionCookie(name: 'SID', value: 'auth', domain: '.example.com'),
      ];
      final header =
          await service.liveCookieHeaderFor('https://lh3.example.com/media?x=1');
      expect(header.split('; ')..sort(), ['HOSTC=h', 'SID=auth']);
    });

    test('liveCookieHeaderFor returns empty when the jar has nothing', () async {
      expect(await service.liveCookieHeaderFor('https://none.example.com/'), '');
    });

    test('host-only cookie is scoped to the captured host', () async {
      // Host-only cookie (no Domain) captured on a.example.com must go to that
      // exact host but not to a sibling host b.example.com.
      await saveSession('https://a.example.com/', const [
        WebSessionCookie(name: 'host', value: 'only'),
      ]);

      expect(await service.cookieHeaderFor('https://a.example.com/'), 'host=only');
      expect(await service.cookieHeaderFor('https://b.example.com/'), '');
    });
  });
}
