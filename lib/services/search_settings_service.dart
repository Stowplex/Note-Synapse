import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';

const String _pdfPageCapKey = 'search_index_pdf_page_cap';
const String _ocrScriptKey = 'search_index_ocr_script';
const String _ocrEnabledKey = 'search_index_ocr_enabled';
const String _figureIndexingEnabledKey = 'search_index_figures_enabled';
const String _embedWifiOnlyKey = 'search_embedding_wifi_only';
const String _embeddingConsentKeyPrefix = 'search_embedding_consent_';

/// Service to manage search-index settings persistence.
///
/// Mirrors the SharedPreferences pattern of [NetworkSettingsService] /
/// [ConversationSettingsService]. The settings UI (search settings screen)
/// wires these values; the indexing pipeline reads them.
class SearchSettingsService {
  /// Connectivity probe behind the wifi-only backfill gate. Injectable
  /// because `connectivity_plus` is a platform channel: it throws
  /// MissingPluginException under `flutter test`.
  final Future<List<ConnectivityResult>> Function()? _connectivityCheck;

  SearchSettingsService({
    Future<List<ConnectivityResult>> Function()? connectivityCheck,
  }) : _connectivityCheck = connectivityCheck;

  /// Default page cap for automatic PDF text extraction (plan §1.3
  /// size-gated defaults): PDFs with more pages than this are not indexed
  /// unless the user explicitly opts the attachment in
  /// (`AttachmentSearchIndexConfig.text == 'on'`).
  static const int defaultPdfPageCap = 100;

  /// Minimum accepted page cap.
  static const int minPdfPageCap = 1;

  /// Maximum accepted page cap.
  static const int maxPdfPageCap = 10000;

  /// Page cap above which PDF text extraction is skipped by default
  /// (`searchIndexPdfPageCap`).
  Future<int> getPdfPageCap() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_pdfPageCapKey);
    if (value == null || value < minPdfPageCap || value > maxPdfPageCap) {
      return defaultPdfPageCap;
    }
    return value;
  }

  Future<void> setPdfPageCap(int cap) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pdfPageCapKey, cap.clamp(minPdfPageCap, maxPdfPageCap));
  }

  /// Valid values for the OCR script setting.
  static const List<String> ocrScriptValues = ['auto', 'latin', 'chinese'];

  /// Which ML Kit script recognizer the OCR stage uses: 'latin', 'chinese',
  /// or 'auto' (default — follow the device locale; zh picks the Chinese
  /// recognizer). See AttachmentOcrExtractor for the script policy.
  Future<String> getOcrScript() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_ocrScriptKey);
    if (value == null || !ocrScriptValues.contains(value)) return 'auto';
    return value;
  }

  Future<void> setOcrScript(String script) async {
    if (!ocrScriptValues.contains(script)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ocrScriptKey, script);
  }

  /// Global on/off for the on-device OCR layer (plan §3: OCR is a primary
  /// layer, ENABLED by default because it runs entirely on-device, but it is
  /// sustained CPU work so it stays toggleable). Per-attachment
  /// `metadata.searchIndex.ocr` still applies on top of this.
  Future<bool> getOcrEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_ocrEnabledKey) ?? true;
  }

  Future<void> setOcrEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ocrEnabledKey, enabled);
  }

  /// Global on/off for figure-region extraction + figure chunks (plan §4.1).
  /// On by default: figure chunks are lexically findable with no provider,
  /// and the extraction rides on data the OCR/PDF-text stages already
  /// produced.
  Future<bool> getFigureIndexingEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_figureIndexingEnabledKey) ?? true;
  }

  Future<void> setFigureIndexingEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_figureIndexingEnabledKey, enabled);
  }

  /// Whether the embedding BACKFILL is restricted to unmetered networks.
  /// Defaults to ON (plan §2.2: "wifi-only backfill defaults ON for cloud
  /// providers"). Query embeddings are unaffected — they are one small
  /// request per search and may use any network.
  Future<bool> getEmbedWifiOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_embedWifiOnlyKey) ?? true;
  }

  Future<void> setEmbedWifiOnly(bool wifiOnly) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_embedWifiOnlyKey, wifiOnly);
  }

  /// Transports that count as "unmetered enough" for the wifi-only backfill
  /// gate.
  ///
  /// [ConnectivityResult.vpn] and [ConnectivityResult.other] are in the list
  /// on purpose. connectivity_plus reports the ACTIVE network's transports
  /// verbatim: with a VPN up, Android commonly reports `[vpn]` alone (the
  /// underlying Wi-Fi transport is not surfaced), and iOS/macOS report
  /// `other` for a VPN because they have no separate VPN interface type.
  /// Treating those as "not Wi-Fi" deferred the backfill forever on a real
  /// Wi-Fi network, with nothing in the UI to explain the stall. The cost of
  /// the looser list is the reverse case — a VPN riding cellular is billed as
  /// unmetered — which the user can avoid by turning the wifi-only setting
  /// off (or leaving it on and connecting to Wi-Fi).
  static const Set<ConnectivityResult> unmeteredTransports = {
    ConnectivityResult.wifi,
    ConnectivityResult.ethernet,
    ConnectivityResult.vpn,
    ConnectivityResult.other,
  };

  /// The `embedNetworkAllowed` seam NoteIndexService consults before each
  /// embed batch: false DEFERS the pass (the next sweep re-evaluates).
  ///
  /// [isCloudProvider] false (an on-device provider) always passes — nothing
  /// leaves the device, so the wifi-only setting is irrelevant there. The
  /// caller supplies this because the seam itself carries no provider
  /// argument; see the service_locator wiring.
  ///
  /// Fails CLOSED: when connectivity cannot be determined (platform channel
  /// missing, plugin error, empty result) the pass is deferred, not allowed.
  /// The two failure modes are not symmetric — failing open silently uploads
  /// the corpus over cellular against an explicit setting, while failing
  /// closed only postpones work the next sweep retries.
  Future<bool> embedBackfillNetworkAllowed({
    bool isCloudProvider = true,
  }) async {
    if (!isCloudProvider) return true;
    if (!await getEmbedWifiOnly()) return true;
    try {
      final check = _connectivityCheck ?? Connectivity().checkConnectivity;
      final results = await check();
      if (results.isEmpty) {
        LoggerService.warning(
          'SearchSettingsService: connectivity check returned no transports '
          '— deferring embedding backfill (wifi-only is on)',
        );
        return false;
      }
      return results.any(unmeteredTransports.contains);
    } catch (e) {
      LoggerService.warning(
        'SearchSettingsService: connectivity check failed ($e) — '
        'deferring embedding backfill (wifi-only is on)',
      );
      return false;
    }
  }

  /// Whether the user granted the one-time embedding consent (plan §2.2:
  /// "~N chunks of note text will be sent to X") for [providerKey].
  ///
  /// Consent is recorded PER providerKey: switching to a new provider (or a
  /// dims change — a new providerKey) requires a fresh consent, while
  /// re-enabling a previously consented provider does not. Default: no
  /// consent recorded → false, and the embed pipeline stage no-ops. Step 10's
  /// settings dialog writes this via [setEmbeddingConsent]; the indexer reads
  /// it through its consent-check seam.
  Future<bool> getEmbeddingConsent(String providerKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_embeddingConsentKeyPrefix$providerKey') ?? false;
  }

  Future<void> setEmbeddingConsent(String providerKey, bool granted) async {
    final prefs = await SharedPreferences.getInstance();
    if (granted) {
      await prefs.setBool('$_embeddingConsentKeyPrefix$providerKey', true);
    } else {
      await prefs.remove('$_embeddingConsentKeyPrefix$providerKey');
    }
  }
}
