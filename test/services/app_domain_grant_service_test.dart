import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/app_domain_grant_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDomainGrantService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    service = AppDomainGrantService(prefs: prefs);
  });

  test('isGranted is false before any grant', () async {
    expect(await service.isGranted('app1', 'google.com'), false);
  });

  test('grant then isGranted returns true; scoped per app and domain', () async {
    await service.grant('app1', 'google.com');

    expect(await service.isGranted('app1', 'google.com'), true);
    // Different app and different domain are not granted.
    expect(await service.isGranted('app2', 'google.com'), false);
    expect(await service.isGranted('app1', 'notion.so'), false);
  });

  test('grant is idempotent (no duplicate domains)', () async {
    await service.grant('app1', 'google.com');
    await service.grant('app1', 'google.com');

    expect(await service.domainsForApp('app1'), ['google.com']);
  });

  test('revoke removes a single grant', () async {
    await service.grant('app1', 'google.com');
    await service.grant('app1', 'notion.so');

    await service.revoke('app1', 'google.com');

    expect(await service.isGranted('app1', 'google.com'), false);
    expect(await service.isGranted('app1', 'notion.so'), true);
  });

  test('revokeAllForApp clears every grant for that app only', () async {
    await service.grant('app1', 'google.com');
    await service.grant('app1', 'notion.so');
    await service.grant('app2', 'google.com');

    await service.revokeAllForApp('app1');

    expect(await service.domainsForApp('app1'), isEmpty);
    expect(await service.isGranted('app2', 'google.com'), true);
  });

  test('revokeAllForDomain clears that domain for every app only', () async {
    await service.grant('app1', 'google.com');
    await service.grant('app1', 'notion.so');
    await service.grant('app2', 'google.com');

    await service.revokeAllForDomain('google.com');

    expect(await service.appsForDomain('google.com'), isEmpty);
    // Other domains held by the same apps are untouched.
    expect(await service.isGranted('app1', 'notion.so'), true);
    expect(await service.domainsForApp('app2'), isEmpty);
  });

  test('revokeAllForDomain is a no-op for unknown or empty domain', () async {
    await service.grant('app1', 'google.com');

    await service.revokeAllForDomain('unknown.com');
    await service.revokeAllForDomain('');

    expect(await service.isGranted('app1', 'google.com'), true);
  });

  test('revokeAllForDomain is written through to the store', () async {
    await service.grant('app1', 'google.com');
    await service.grant('app2', 'google.com');
    await service.revokeAllForDomain('google.com');

    // Assert on the persisted bytes: a second service instance shares the same
    // cached SharedPreferences, so reloading one would pass even if _write
    // never ran.
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('app_domain_grants');
    expect(raw, isNotNull);
    expect(raw, isNot(contains('google.com')));
  });

  test('domainsForApp and appsForDomain return sorted results', () async {
    await service.grant('app1', 'notion.so');
    await service.grant('app1', 'google.com');
    await service.grant('app2', 'google.com');

    expect(await service.domainsForApp('app1'), ['google.com', 'notion.so']);
    expect(await service.appsForDomain('google.com'), ['app1', 'app2']);
    expect(await service.appsForDomain('notion.so'), ['app1']);
  });

  test('empty appUuid or domain is ignored', () async {
    await service.grant('', 'google.com');
    await service.grant('app1', '');

    expect(await service.appsForDomain('google.com'), isEmpty);
    expect(await service.domainsForApp('app1'), isEmpty);
  });

  test('grants persist across service instances (same prefs)', () async {
    await service.grant('app1', 'google.com');

    final prefs = await SharedPreferences.getInstance();
    final reloaded = AppDomainGrantService(prefs: prefs);
    expect(await reloaded.isGranted('app1', 'google.com'), true);
  });
}
