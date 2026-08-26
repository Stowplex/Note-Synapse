// Step 10 settings keys + the wifi-only network gate (plan §2.2).

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/search_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('defaults', () {
    test('OCR and figure indexing are on, wifi-only backfill is on', () async {
      final settings = SearchSettingsService();
      expect(await settings.getOcrEnabled(), isTrue);
      expect(await settings.getFigureIndexingEnabled(), isTrue);
      expect(await settings.getEmbedWifiOnly(), isTrue);
    });

    test('each toggle round-trips', () async {
      final settings = SearchSettingsService();
      await settings.setOcrEnabled(false);
      await settings.setFigureIndexingEnabled(false);
      await settings.setEmbedWifiOnly(false);
      expect(await settings.getOcrEnabled(), isFalse);
      expect(await settings.getFigureIndexingEnabled(), isFalse);
      expect(await settings.getEmbedWifiOnly(), isFalse);
    });
  });

  group('PDF page cap', () {
    test('defaults when unset', () async {
      expect(
        await SearchSettingsService().getPdfPageCap(),
        SearchSettingsService.defaultPdfPageCap,
      );
    });

    test('round-trips a value inside the range', () async {
      final settings = SearchSettingsService();
      await settings.setPdfPageCap(1000);
      expect(await settings.getPdfPageCap(), 1000);
    });

    test('writes are clamped to the accepted range', () async {
      final settings = SearchSettingsService();
      await settings.setPdfPageCap(0);
      expect(
        await settings.getPdfPageCap(),
        SearchSettingsService.minPdfPageCap,
      );
      await settings.setPdfPageCap(-5);
      expect(
        await settings.getPdfPageCap(),
        SearchSettingsService.minPdfPageCap,
      );
      await settings.setPdfPageCap(999999);
      expect(
        await settings.getPdfPageCap(),
        SearchSettingsService.maxPdfPageCap,
      );
    });

    test('a stored out-of-range value falls back to the default', () async {
      // Written by an older build (or hand-edited prefs): the reader must
      // not hand the pipeline a cap it would never have accepted.
      SharedPreferences.setMockInitialValues({
        'search_index_pdf_page_cap': 999999,
      });
      expect(
        await SearchSettingsService().getPdfPageCap(),
        SearchSettingsService.defaultPdfPageCap,
      );
    });
  });

  group('OCR script', () {
    test('defaults to auto', () async {
      expect(await SearchSettingsService().getOcrScript(), 'auto');
    });

    test('each accepted value round-trips', () async {
      final settings = SearchSettingsService();
      for (final script in SearchSettingsService.ocrScriptValues) {
        await settings.setOcrScript(script);
        expect(await settings.getOcrScript(), script);
      }
    });

    test('an unknown script is rejected, not stored', () async {
      final settings = SearchSettingsService();
      await settings.setOcrScript('chinese');
      await settings.setOcrScript('klingon');
      expect(await settings.getOcrScript(), 'chinese');
    });

    test('an unknown STORED script reads back as auto', () async {
      SharedPreferences.setMockInitialValues({
        'search_index_ocr_script': 'klingon',
      });
      expect(await SearchSettingsService().getOcrScript(), 'auto');
    });
  });

  group('embedding consent', () {
    test('nothing is consented by default', () async {
      expect(
        await SearchSettingsService().getEmbeddingConsent('openai:m:768'),
        isFalse,
      );
    });

    test('consent is recorded per providerKey', () async {
      final settings = SearchSettingsService();
      await settings.setEmbeddingConsent('openai:m:768', true);
      expect(await settings.getEmbeddingConsent('openai:m:768'), isTrue);
      // A different provider — or the same model at different dims — is a
      // different key and needs its own consent.
      expect(await settings.getEmbeddingConsent('openai:m:1536'), isFalse);
      expect(await settings.getEmbeddingConsent('gemini:m:768'), isFalse);
    });

    test('withdrawing consent removes it', () async {
      final settings = SearchSettingsService();
      await settings.setEmbeddingConsent('openai:m:768', true);
      await settings.setEmbeddingConsent('openai:m:768', false);
      expect(await settings.getEmbeddingConsent('openai:m:768'), isFalse);
    });
  });

  group('embedBackfillNetworkAllowed', () {
    SearchSettingsService withConnectivity(
      List<ConnectivityResult> results, {
      bool throws = false,
    }) {
      return SearchSettingsService(
        connectivityCheck: () async {
          if (throws) throw StateError('no platform channel');
          return results;
        },
      );
    }

    test('wifi and ethernet pass the gate', () async {
      expect(
        await withConnectivity([
          ConnectivityResult.wifi,
        ]).embedBackfillNetworkAllowed(),
        isTrue,
      );
      expect(
        await withConnectivity([
          ConnectivityResult.ethernet,
        ]).embedBackfillNetworkAllowed(),
        isTrue,
      );
    });

    test('a VPN passes the gate', () async {
      // connectivity_plus reports the ACTIVE network's transports verbatim:
      // Android commonly reports [vpn] alone over real Wi-Fi, and iOS/macOS
      // report `other` for a VPN. Rejecting those deferred the backfill
      // forever with nothing in the UI to explain it.
      expect(
        await withConnectivity([
          ConnectivityResult.vpn,
        ]).embedBackfillNetworkAllowed(),
        isTrue,
      );
      expect(
        await withConnectivity([
          ConnectivityResult.other,
        ]).embedBackfillNetworkAllowed(),
        isTrue,
      );
    });

    test('being offline defers the backfill', () async {
      expect(
        await withConnectivity([
          ConnectivityResult.none,
        ]).embedBackfillNetworkAllowed(),
        isFalse,
      );
    });

    test('any unmetered transport in the list is enough', () async {
      expect(
        await withConnectivity([
          ConnectivityResult.mobile,
          ConnectivityResult.wifi,
        ]).embedBackfillNetworkAllowed(),
        isTrue,
      );
    });

    test('mobile data defers the backfill while wifi-only is on', () async {
      expect(
        await withConnectivity([
          ConnectivityResult.mobile,
        ]).embedBackfillNetworkAllowed(),
        isFalse,
      );
    });

    test('turning wifi-only off allows any network', () async {
      final settings = withConnectivity([ConnectivityResult.mobile]);
      await settings.setEmbedWifiOnly(false);
      expect(await settings.embedBackfillNetworkAllowed(), isTrue);
    });

    test('an on-device provider ignores the gate entirely', () async {
      expect(
        await withConnectivity([
          ConnectivityResult.mobile,
        ]).embedBackfillNetworkAllowed(isCloudProvider: false),
        isTrue,
      );
    });

    test('an unanswerable connectivity check fails CLOSED', () async {
      // Asymmetric failure modes (see embedBackfillNetworkAllowed): failing
      // open would upload the corpus over cellular against an explicit
      // setting, while failing closed only postpones work the next sweep
      // retries. Both an error and an empty transport list defer.
      expect(
        await withConnectivity(
          const [],
          throws: true,
        ).embedBackfillNetworkAllowed(),
        isFalse,
      );
      expect(
        await withConnectivity(const []).embedBackfillNetworkAllowed(),
        isFalse,
      );
    });
  });
}
