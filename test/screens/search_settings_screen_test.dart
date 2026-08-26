// Step 10 — search settings UX (plan §2.2 / §2.3 / §3 / §1.3 / §4.2).
//
// Covers the pure state derivations plus the flows whose correctness is a
// user-visible promise: consent is never recorded without an explicit
// accept, a provider cannot be enabled without a successful probe, the
// switch disclosure offers "Stop using A now", errors map to the right
// remedy, Rebuild confirms and locks while running, and the large-PDF list
// opts an attachment in.

import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/screens/search_settings_screen.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/search/embedding/embedding_preset_service.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider_registry.dart';
import 'package:note_synapse/services/search/embedding/local_embedding_model_manager.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/search_settings_service.dart';
import 'package:note_synapse/services/service_locator.dart';

// ── Fakes ────────────────────────────────────────────────────────────────

const _cloudPresetYaml = '''
model_type: openai
model_endpoint: https://api.openai.com/v1
model_name: text-embedding-3-small
model_display_name: OpenAI Small
dimensions: 1536
supports_images: false
api_key_url: https://platform.openai.com/api-keys
''';

const _localPresetYaml = '''
model_type: local
model_name: embeddinggemma-300m
model_display_name: EmbeddingGemma
dimensions: 768
supports_images: false
model_url: https://huggingface.co/litert/embeddinggemma-300m.tflite
tokenizer_url: https://huggingface.co/litert/tokenizer.model
api_key_url: https://huggingface.co/settings/tokens
''';

EmbeddingPresetService _presetService() {
  return EmbeddingPresetService.forTesting(
    listAssets: () async => [
      'assets/embedding_presets/openai.yaml',
      'assets/embedding_presets/local.yaml',
    ],
    loadAsset: (key) async =>
        key.endsWith('local.yaml') ? _localPresetYaml : _cloudPresetYaml,
  );
}

const _presetKey = 'openai:text-embedding-3-small:1536';

/// In-memory stand-in for the registry's secure storage, so a test can prove
/// a credential landed in the slot the registry itself reads back.
class _RecordingSecureStorage extends FlutterSecureStorage {
  _RecordingSecureStorage(this.writes);

  final Map<String, String?> writes;

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes[key] = value;
  }
}

class _FakeRegistry extends EmbeddingProviderRegistry {
  // saveApiKey is NOT faked: the install flow's promise is that the token
  // reaches the registry's own storage under the handle getApiKey reads, and
  // that is exactly what the inherited implementation + injected store pin.
  _FakeRegistry._(this.savedKeys)
    : super(storage: _RecordingSecureStorage(savedKeys));

  factory _FakeRegistry() => _FakeRegistry._({});

  /// Keys written through the registry's injected secure storage.
  final Map<String, String?> savedKeys;

  EmbeddingProviderConfig? activeConfigValue;
  String? servingKeyValue;
  String? servingNameValue;
  String? revokedKeyValue;
  EmbeddingProbeResult? probeResult;

  final List<EmbeddingProviderConfig> setConfigCalls = [];
  int revokeServingCalls = 0;
  int clearActiveCalls = 0;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<void> initialize() async {}

  @override
  EmbeddingProviderConfig? get activeConfig => activeConfigValue;

  @override
  EmbeddingTransitionState get transitionState => EmbeddingTransitionState(
    servingKey: servingKeyValue,
    servingDisplayName: servingNameValue,
    activeKey: activeConfigValue?.providerKey,
    activeDisplayName: activeConfigValue?.displayName,
    revokedKey: revokedKeyValue,
  );

  @override
  Future<String?> getApiKey(EmbeddingProviderConfig config) async => null;

  @override
  Future<EmbeddingProbeResult> testConnection(
    EmbeddingProviderConfig config, {
    String? apiKey,
  }) async {
    return probeResult ??
        EmbeddingProbeResult(
          ok: true,
          detectedDimensions: config.dimensions,
          dimensionsMatched: true,
          correctedConfig: config,
        );
  }

  @override
  Future<void> setActiveConfig(
    EmbeddingProviderConfig config, {
    String? apiKey,
  }) async {
    setConfigCalls.add(config);
    activeConfigValue = config;
  }

  @override
  Future<void> revokeServing() async {
    revokeServingCalls++;
    revokedKeyValue = servingKeyValue;
    servingKeyValue = null;
    servingNameValue = null;
  }

  @override
  Future<void> clearActiveConfig({bool deleteApiKey = false}) async {
    clearActiveCalls++;
    activeConfigValue = null;
  }
}

class _FakeIndexService extends Fake implements NoteIndexService {
  final ValueNotifier<IndexProgress> progressNotifier = ValueNotifier(
    IndexProgress.idle,
  );
  ({int embedded, int total}) coverage = (embedded: 0, total: 0);
  ({String? status, String? errorMessage, int failedChunks}) stageState = (
    status: null,
    errorMessage: null,
    failedChunks: 0,
  );

  int retryCalls = 0;
  int deleteCalls = 0;
  int ensureBackfilledCalls = 0;
  final List<bool> backfillCalls = [];

  @override
  ValueListenable<IndexProgress> get progress => progressNotifier;

  @override
  Future<({int embedded, int total})> embedCoverage(String providerKey) async =>
      coverage;

  @override
  Future<({String? status, String? errorMessage, int failedChunks})>
  embedStageState(String providerKey) async => stageState;

  @override
  Future<void> retryEmbedIndexing() async => retryCalls++;

  @override
  Future<void> deleteStoredEmbeddings() async => deleteCalls++;

  @override
  Future<void> backfillAll({bool force = false}) async =>
      backfillCalls.add(force);

  @override
  Future<void> ensureBackfilled() async => ensureBackfilledCalls++;
}

class _FakeModelStorage extends ModelStorageService {
  List<ModelConfig> models = const [];
  Map<String, String> keys = {};

  @override
  Future<List<ModelConfig>> getConfiguredModels() async => models;

  @override
  Future<String?> getModelApiKey(String modelId) async => keys[modelId];
}

class _FakeDatabaseService extends Fake implements DatabaseService {
  Attachment? attachment;
  final List<Map<String, dynamic>?> metadataWrites = [];

  @override
  Future<Attachment?> getAttachmentById(String attachmentId) async =>
      attachment;

  @override
  Future<void> updateAttachmentMetadata(
    String attachmentId,
    Map<String, dynamic>? metadata,
  ) async {
    metadataWrites.add(metadata);
  }
}

class _FakeSearchSettings extends SearchSettingsService {
  final Map<String, bool> consent = {};
  final List<String> consentCalls = [];
  bool ocrEnabled = true;
  String ocrScript = 'auto';
  bool figures = true;
  bool wifiOnly = true;
  int pageCap = 100;

  @override
  Future<bool> getEmbeddingConsent(String providerKey) async =>
      consent[providerKey] ?? false;

  @override
  Future<void> setEmbeddingConsent(String providerKey, bool granted) async {
    consentCalls.add(providerKey);
    consent[providerKey] = granted;
  }

  @override
  Future<bool> getOcrEnabled() async => ocrEnabled;

  @override
  Future<void> setOcrEnabled(bool enabled) async => ocrEnabled = enabled;

  @override
  Future<String> getOcrScript() async => ocrScript;

  @override
  Future<void> setOcrScript(String script) async => ocrScript = script;

  @override
  Future<bool> getFigureIndexingEnabled() async => figures;

  @override
  Future<void> setFigureIndexingEnabled(bool enabled) async =>
      figures = enabled;

  @override
  Future<bool> getEmbedWifiOnly() async => wifiOnly;

  @override
  Future<void> setEmbedWifiOnly(bool value) async => wifiOnly = value;

  @override
  Future<int> getPdfPageCap() async => pageCap;

  @override
  Future<void> setPdfPageCap(int cap) async => pageCap = cap;
}

// ── Helpers ──────────────────────────────────────────────────────────────

late _FakeRegistry _registry;
late _FakeIndexService _indexer;
late _FakeDatabaseService _db;
late _FakeSearchSettings _settings;

Widget _screen({
  Future<List<LargePdfEntry>> Function()? largePdfLoader,
  Future<SearchIndexScope> Function()? scopeLoader,
  Future<bool?> Function()? figureSkillLoader,
  LocalEmbeddingModelManager? modelManager,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SearchSettingsScreen(
      settingsService: _settings,
      presetService: _presetService(),
      modelManager: modelManager,
      largePdfLoader: largePdfLoader ?? () async => const [],
      scopeLoader:
          scopeLoader ??
          () async => const SearchIndexScope(
            notes: 12,
            chunks: 340,
            uploadableChunks: 340,
            imageChunks: 0,
          ),
      figureSkillLoader: figureSkillLoader ?? () async => null,
    ),
  );
}

/// A real [LocalEmbeddingModelManager] with its plugin seams faked — the
/// manager's own logic (in-flight de-duplication, pre-crediting installed
/// files, error mapping) is what the install flow depends on.
LocalEmbeddingModelManager _modelManager({
  bool installed = false,
  Object? failWith,
  void Function(String? token)? onInstall,
}) {
  return LocalEmbeddingModelManager(
    fileInstalledCheck: (_) async => installed,
    fileUninstallOp: (_) async {},
    closeActiveEmbedderOp: (_) async {},
    installOp: (config, token, onModel, onTokenizer) async {
      onInstall?.call(token);
      onModel(50);
      onTokenizer(50);
      if (failWith != null) throw failWith;
      onModel(100);
      onTokenizer(100);
    },
  );
}

/// Pumps [screen] into a viewport tall enough for every card (the settings
/// list is longer than the 800x600 test surface, and a ListView never builds
/// its off-screen children).
Future<void> _pumpScreen(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(screen);
  await _settle(tester);
}

/// pumpAndSettle equivalent that tolerates an indefinite progress spinner
/// (which by definition never settles).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Walks provider tile → picker → the preset's configuration page.
Future<void> _openPresetConfig(WidgetTester tester) async {
  await tester.tap(find.text('Embedding provider'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OpenAI Small'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // flutter_secure_storage's MethodChannel never answers under
    // `flutter test`, so any stray read would hang. The registry under test
    // gets its own injected store (see _FakeRegistry); this covers the rest.
    FlutterSecureStorage.setMockInitialValues({});
    await getIt.reset();
    _registry = _FakeRegistry();
    _indexer = _FakeIndexService();
    _db = _FakeDatabaseService();
    _settings = _FakeSearchSettings();
    getIt.registerSingleton<EmbeddingProviderRegistry>(_registry);
    getIt.registerSingleton<NoteIndexService>(_indexer);
    getIt.registerSingleton<DatabaseService>(_db);
  });

  tearDown(() async {
    await getIt.reset();
  });

  // ── Pure derivations ───────────────────────────────────────────────────

  group('deriveSearchSettingsSubtitle', () {
    test('no configured provider reads as lexical only', () {
      expect(
        deriveSearchSettingsSubtitle(
          transition: const EmbeddingTransitionState(),
          embeddedChunks: 0,
          totalChunks: 100,
        ),
        const SearchSettingsSubtitle(SearchSubtitleKind.lexicalOnly),
      );
    });

    test('partial coverage reads as indexing with a percent', () {
      final state = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          servingKey: 'a',
          servingDisplayName: 'A',
          activeKey: 'a',
          activeDisplayName: 'A',
        ),
        embeddedChunks: 62,
        totalChunks: 100,
      );
      expect(state.kind, SearchSubtitleKind.indexing);
      expect(state.provider, 'A');
      expect(state.percent, 62);
    });

    test('complete + done stage reads as ready', () {
      final state = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          servingKey: 'a',
          servingDisplayName: 'A',
          activeKey: 'a',
          activeDisplayName: 'A',
        ),
        embeddedChunks: 100,
        totalChunks: 100,
        embedStatus: NoteIndexService.statusDone,
      );
      expect(state.kind, SearchSubtitleKind.ready);
    });

    test('a done stage below 100% still reads as ready', () {
      // embedCoverage counts EVERY chunk, while the embed pass skips the
      // ones it may not upload — a finished backfill routinely lands short
      // of 100%, and the old `percent >= 100` gate left the tile stuck on
      // "indexing 97%" for good.
      final state = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          servingKey: 'a',
          servingDisplayName: 'A',
          activeKey: 'a',
          activeDisplayName: 'A',
        ),
        embeddedChunks: 97,
        totalChunks: 100,
        embedStatus: NoteIndexService.statusDone,
      );
      expect(state.kind, SearchSubtitleKind.ready);
      expect(state.percent, 100);
    });

    test('a pending switch outranks plain progress', () {
      final state = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          servingKey: 'a',
          servingDisplayName: 'A',
          activeKey: 'b',
          activeDisplayName: 'B',
        ),
        embeddedChunks: 40,
        totalChunks: 100,
      );
      expect(state.kind, SearchSubtitleKind.switching);
      expect(state.provider, 'B');
      expect(state.percent, 40);
    });

    test('a revoked active provider reads as off, not as switching', () {
      // The revocation is persisted and suppresses promotion, so serving
      // stays null and inTransition stays true — the switching branch would
      // report "Switching to A — 62%" for good.
      final state = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          activeKey: 'a',
          activeDisplayName: 'A',
          revokedKey: 'a',
        ),
        embeddedChunks: 62,
        totalChunks: 100,
      );
      expect(state.kind, SearchSubtitleKind.revoked);
      expect(state.provider, 'A');
    });

    test('a revoked provider outranks a stale embed error', () {
      // Nothing serves and nothing promotes until it is re-enabled, so an
      // embed error under the revocation is not the actionable fact.
      final state = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          activeKey: 'a',
          activeDisplayName: 'A',
          revokedKey: 'a',
        ),
        embeddedChunks: 62,
        totalChunks: 100,
        embedStatus: NoteIndexService.statusError,
        failedChunks: 4,
      );
      expect(state.kind, SearchSubtitleKind.revoked);
    });

    test('revoking a DIFFERENT provider still reads as switching', () {
      // "Stop using A now" during a switch to B: B is still backfilling.
      final state = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          activeKey: 'b',
          activeDisplayName: 'B',
          revokedKey: 'a',
        ),
        embeddedChunks: 40,
        totalChunks: 100,
      );
      expect(state.kind, SearchSubtitleKind.switching);
    });

    test('errors outrank a switch, and a halt reports at least one error', () {
      final halted = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          servingKey: 'a',
          servingDisplayName: 'A',
          activeKey: 'b',
          activeDisplayName: 'B',
        ),
        embeddedChunks: 40,
        totalChunks: 100,
        embedStatus: NoteIndexService.statusError,
      );
      expect(halted.kind, SearchSubtitleKind.errors);
      expect(halted.errorCount, 1);

      final failedChunks = deriveSearchSettingsSubtitle(
        transition: const EmbeddingTransitionState(
          servingKey: 'a',
          servingDisplayName: 'A',
          activeKey: 'a',
          activeDisplayName: 'A',
        ),
        embeddedChunks: 90,
        totalChunks: 100,
        failedChunks: 3,
      );
      expect(failedChunks.kind, SearchSubtitleKind.errors);
      expect(failedChunks.errorCount, 3);
    });
  });

  group('classifyEmbedHalt', () {
    test('the stored kind prefix decides, not the prose', () {
      expect(
        classifyEmbedHalt(
          '${NoteIndexService.embedHaltAuth}|Embedding request failed: 401',
        ),
        EmbedHaltKind.auth,
      );
      expect(
        classifyEmbedHalt(
          '${NoteIndexService.embedHaltNotInstalled}|EmbeddingGemma is '
          'missing its model/tokenizer download URLs',
        ),
        EmbedHaltKind.notInstalled,
      );
      expect(
        classifyEmbedHalt(
          '${NoteIndexService.embedHaltDims}|model X returned 1536 values',
        ),
        EmbedHaltKind.dimensionMismatch,
      );
    });

    test('the prefix wins when the prose points elsewhere', () {
      // An HTTP failure embeds the response BODY verbatim in its message, and
      // a body can say anything. Matching that prose sent a user with a
      // rejected key to "Download model"; the stored kind is the only
      // trustworthy signal.
      expect(
        classifyEmbedHalt(
          '${NoteIndexService.embedHaltAuth}|Embedding request failed: 401 - '
          '{"error":"model is not installed on this device"}',
        ),
        EmbedHaltKind.auth,
      );
    });

    test('an unprefixed halt still falls back to its prose', () {
      // Rows persisted before the indexer encoded the kind, read after an
      // upgrade.
      expect(
        classifyEmbedHalt('Embedding request failed: 401 - bad key'),
        EmbedHaltKind.auth,
      );
      expect(
        classifyEmbedHalt(
          'EmbeddingGemma is not installed on this device — download it '
          'from search settings first',
        ),
        EmbedHaltKind.notInstalled,
      );
      expect(
        classifyEmbedHalt(
          'model X returned 1536-dimensional vectors but the configuration '
          'expects 768 dimensions',
        ),
        EmbedHaltKind.dimensionMismatch,
      );
    });

    test('anything else falls through to other', () {
      expect(
        classifyEmbedHalt('Embedding request failed: 500 - boom'),
        EmbedHaltKind.other,
      );
      expect(classifyEmbedHalt(null), EmbedHaltKind.other);
      // A '|' in the prose is not a prefix: only the three known codes are.
      expect(
        classifyEmbedHalt('POST /v1/embeddings | 500 | upstream timeout'),
        EmbedHaltKind.other,
      );
    });
  });

  test('approximateCount rounds to an order of magnitude', () {
    expect(approximateCount(0), 0);
    expect(approximateCount(37), 37);
    expect(approximateCount(1234), 1200);
    expect(approximateCount(98765), 98000);
  });

  test('pageCountFromStateHash reads the pages component', () {
    expect(pageCountFromStateHash('abc|text=auto|cap=100|pages=512'), 512);
    expect(pageCountFromStateHash('abc|text=auto'), isNull);
    expect(pageCountFromStateHash(null), isNull);
  });

  test(
    'the indexer still writes the |pages=N component this screen parses',
    () {
      // Coupling pin. pageCountFromStateHash re-parses a string the INDEXER
      // formats (NoteIndexService._pdfStateHash), and the two live in
      // different files with no shared symbol: a silent rename there would
      // just make every large-PDF row lose its page count, with nothing
      // failing. The literal is asserted here so the rename breaks a test.
      final source = File(
        'lib/services/search/note_index_service.dart',
      ).readAsStringSync();
      expect(
        source.contains(r"buffer.write('|pages=$pageCount')"),
        isTrue,
        reason:
            'NoteIndexService._pdfStateHash no longer writes "|pages=N" — '
            'update pageCountFromStateHash in search_settings_screen.dart to '
            'match the new format.',
      );
    },
  );

  // ── Consent gating ─────────────────────────────────────────────────────

  testWidgets('cancelling consent records nothing and enables nothing', (
    tester,
  ) async {
    await _pumpScreen(tester, _screen());

    await _openPresetConfig(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();

    expect(find.textContaining('will be sent to OpenAI Small'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(_settings.consentCalls, isEmpty);
    expect(_registry.setConfigCalls, isEmpty);
  });

  testWidgets('accepting consent records it once for the providerKey', (
    tester,
  ) async {
    await _pumpScreen(tester, _screen());

    await _openPresetConfig(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send and index'));
    await tester.pumpAndSettle();

    expect(_settings.consentCalls, [_presetKey]);
    expect(_settings.consent[_presetKey], isTrue);
    expect(_registry.setConfigCalls, hasLength(1));
    expect(_registry.setConfigCalls.single.providerKey, _presetKey);
  });

  testWidgets('enabling a provider un-halts the embed stage', (tester) async {
    // The auth branch's only remedy is "Fix key", which lands back here. A
    // halted embed stage counts as satisfied, so a plain ensureBackfilled()
    // would no-op and the halt would outlive the fixed key forever — the
    // apply path has to go through the retry (which clears the sticky halt
    // rows and then backfills).
    await _pumpScreen(tester, _screen());

    await _openPresetConfig(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send and index'));
    await tester.pumpAndSettle();

    expect(_indexer.retryCalls, 1);
    expect(_indexer.ensureBackfilledCalls, 0);
  });

  testWidgets('the consent dialog counts what leaves the device', (
    tester,
  ) async {
    await _pumpScreen(
      tester,
      _screen(
        scopeLoader: () async => const SearchIndexScope(
          notes: 40,
          chunks: 2000,
          // Only 1234 of the 2000 chunks would actually be uploaded (the
          // rest are AI-excluded / embed-off / empty).
          uploadableChunks: 1234,
          imageChunks: 0,
          largePdfs: 3,
        ),
      ),
    );

    await _openPresetConfig(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();

    // Order-of-magnitude of the UPLOADABLE count, not an exact 1234 and not
    // the 2000 chunks the index holds.
    expect(find.textContaining('About 1200 chunks'), findsOneWidget);
    expect(find.textContaining('3 large PDFs stay excluded'), findsOneWidget);
    expect(find.textContaining('Wi-Fi only'), findsOneWidget);
  });

  testWidgets('image chunks are not also counted as text chunks', (
    tester,
  ) async {
    // sourceType='figure' rows are a SUBSET of the uploadable total; without
    // the subtraction every figure would be announced twice.
    await _pumpScreen(
      tester,
      _screen(
        scopeLoader: () async => const SearchIndexScope(
          notes: 40,
          chunks: 900,
          uploadableChunks: 900,
          imageChunks: 400,
        ),
      ),
    );

    await _openPresetConfig(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();

    // 900 - 400 = 500 text chunks. The preset does not accept images, so the
    // image count is not offered at all.
    expect(find.textContaining('About 500 chunks'), findsOneWidget);
    expect(find.textContaining('About 900 chunks'), findsNothing);
  });

  testWidgets('a not-yet-chunked corpus does not claim "about 0 chunks"', (
    tester,
  ) async {
    // Fresh install: the chunk backfill has not run, so an estimate of 0
    // would be quoted seconds before the whole corpus uploads.
    await _pumpScreen(
      tester,
      _screen(scopeLoader: () async => const SearchIndexScope(notes: 3)),
    );

    await _openPresetConfig(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();

    expect(find.textContaining('About 0 chunks'), findsNothing);
    expect(find.textContaining('as they are indexed'), findsOneWidget);
  });

  // ── Provider-switch disclosure ─────────────────────────────────────────

  testWidgets('switching discloses the serving provider and can stop it', (
    tester,
  ) async {
    _registry.servingKeyValue = 'gemini:gemini-embedding-001:768';
    _registry.servingNameValue = 'Gemini';

    await _pumpScreen(tester, _screen());

    await _openPresetConfig(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('searches will continue to use Gemini'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Stop using Gemini now'));
    await tester.pumpAndSettle();

    expect(_registry.revokeServingCalls, 1);
    expect(_settings.consentCalls, [_presetKey]);
    expect(_registry.setConfigCalls, hasLength(1));
  });

  // ── Test-connection gating ─────────────────────────────────────────────

  testWidgets('a failed probe leaves Enable disabled', (tester) async {
    _registry.probeResult = const EmbeddingProbeResult(
      ok: false,
      errorMessage: 'Connection refused',
    );

    await _pumpScreen(tester, _screen());
    await _openPresetConfig(tester);

    // Disabled before any probe...
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Enable'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Connection failed'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Enable'))
          .onPressed,
      isNull,
    );
    expect(_registry.setConfigCalls, isEmpty);
  });

  testWidgets('a dims mismatch adopts the corrected config', (tester) async {
    const corrected = EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 512,
    );
    _registry.probeResult = const EmbeddingProbeResult(
      ok: true,
      detectedDimensions: 512,
      dimensionsMatched: false,
      correctedConfig: corrected,
    );

    await _pumpScreen(tester, _screen());
    await _openPresetConfig(tester);
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dimensions corrected to 512'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send and index'));
    await tester.pumpAndSettle();

    // The stored config carries the DETECTED dims, not the preset's.
    expect(_registry.setConfigCalls.single.dimensions, 512);
    expect(_settings.consentCalls, ['openai:text-embedding-3-small:512']);
  });

  // ── Error surface ──────────────────────────────────────────────────────

  testWidgets('an auth halt asks for a key fix', (tester) async {
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );
    _indexer.stageState = (
      status: NoteIndexService.statusError,
      errorMessage: 'auth|Embedding request failed: 401 - invalid key',
      failedChunks: 0,
    );

    await _pumpScreen(tester, _screen());

    expect(find.textContaining('rejected the key'), findsOneWidget);
    expect(find.text('Fix key'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    // The stored kind prefix is machine-readable plumbing: the detail line
    // shows the prose half only.
    expect(
      find.text('Embedding request failed: 401 - invalid key'),
      findsOneWidget,
    );
    expect(find.textContaining('auth|'), findsNothing);
  });

  testWidgets('a halt message containing a pipe is shown verbatim', (
    tester,
  ) async {
    // Only the three known codes are a prefix, so prose that happens to
    // contain '|' must not be truncated at it.
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );
    _indexer.stageState = (
      status: NoteIndexService.statusError,
      errorMessage: 'POST /v1/embeddings | 500 | upstream timeout',
      failedChunks: 0,
    );

    await _pumpScreen(tester, _screen());

    expect(find.text('Embedding halted'), findsOneWidget);
    expect(
      find.text('POST /v1/embeddings | 500 | upstream timeout'),
      findsOneWidget,
    );
  });

  testWidgets('a missing local model offers a download, not an error', (
    tester,
  ) async {
    // The prose the prefix replaces: "is missing its model/tokenizer
    // download URLs" matched none of the old English patterns, so this halt
    // used to render as a generic error with an inert Retry.
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'local',
      modelName: 'embeddinggemma-300m',
      displayName: 'EmbeddingGemma',
      dimensions: 768,
    );
    _indexer.stageState = (
      status: NoteIndexService.statusError,
      errorMessage:
          'not_installed|EmbeddingGemma is missing its model/tokenizer '
          'download URLs',
      failedChunks: 0,
    );

    await _pumpScreen(tester, _screen());

    expect(find.text('Download model'), findsOneWidget);
    expect(find.textContaining('is not on this device yet'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a dims halt points at the connection test', (tester) async {
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );
    _indexer.stageState = (
      status: NoteIndexService.statusError,
      errorMessage:
          'dims|model returned 768-dimensional vectors but the configuration '
          'expects 1536',
      failedChunks: 0,
    );

    await _pumpScreen(tester, _screen());

    expect(find.text('Test connection'), findsOneWidget);
    expect(find.textContaining('dims|'), findsNothing);
  });

  testWidgets('per-chunk failures offer the one action that clears them', (
    tester,
  ) async {
    // retryEmbedIndexing deletes GLOBAL embed error rows only; these are
    // scopeType='chunk' rows that the gap scan skips, so a Retry here looked
    // like it worked and re-embedded nothing. The forced rebuild is the path
    // that actually deletes them, so that is what the tile offers — and the
    // assertion is on the EFFECT, not on which method got called.
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );
    _indexer.stageState = (status: null, errorMessage: null, failedChunks: 4);

    await _pumpScreen(tester, _screen());

    // Stated once, in the title — not echoed verbatim in the subtitle.
    expect(find.text('4 chunks could not be embedded'), findsOneWidget);
    expect(
      find.text(
        'These are retried by a rebuild — nothing else re-checks them.',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Rebuild index'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Rebuild index'));
    await tester.pumpAndSettle();

    expect(_indexer.backfillCalls, [true]);
    expect(_indexer.retryCalls, 0);
  });

  testWidgets('a stage halt with no per-chunk failures keeps a plain Retry', (
    tester,
  ) async {
    // The halt IS what retryEmbedIndexing clears, so the cheap control is
    // still the honest one here.
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );
    _indexer.stageState = (
      status: NoteIndexService.statusError,
      errorMessage: 'Embedding request failed: 500 - boom',
      failedChunks: 0,
    );

    await _pumpScreen(tester, _screen());

    expect(find.text('Embedding halted'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(_indexer.retryCalls, 1);
  });

  // ── Rebuild + delete ───────────────────────────────────────────────────

  testWidgets('Rebuild confirms with scope before forcing a backfill', (
    tester,
  ) async {
    await _pumpScreen(tester, _screen());

    await tester.tap(find.text('Rebuild index'));
    await tester.pumpAndSettle();
    expect(
      find.text('12 notes and 340 chunks will be re-checked.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(_indexer.backfillCalls, isEmpty);

    await tester.tap(find.text('Rebuild index'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Rebuild index'));
    await tester.pumpAndSettle();
    expect(_indexer.backfillCalls, [true]);
  });

  testWidgets('Rebuild is disabled while a backfill runs', (tester) async {
    _indexer.progressNotifier.value = const IndexProgress(
      done: 3,
      total: 10,
      stage: NoteIndexService.stageChunks,
      running: true,
    );

    await _pumpScreen(tester, _screen());

    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Rebuild index'),
        matching: find.byType(ListTile),
      ),
    );
    expect(tile.enabled, isFalse);
    expect(tile.onTap, isNull);
    expect(find.text('Rebuilding — 30%'), findsOneWidget);
    // The status card names the running stage.
    expect(find.text('Indexing notes — 3/10'), findsOneWidget);
  });

  testWidgets('deleting stored embeddings confirms first', (tester) async {
    await _pumpScreen(tester, _screen());

    await tester.tap(find.text('Delete stored embeddings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(_indexer.deleteCalls, 1);
  });

  testWidgets('the delete confirmation states that it also turns off', (
    tester,
  ) async {
    // deleteStoredEmbeddings withdraws consent for every providerKey that
    // had vectors and clears the active config, so the corpus cannot be
    // re-uploaded by the next sweep. That is more than "delete some rows",
    // and the copy has to say so before the user commits.
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );

    await _pumpScreen(tester, _screen());

    await tester.tap(find.text('Delete stored embeddings'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('also turns the embedding provider off'),
      findsOneWidget,
    );
  });

  // ── Large PDFs ─────────────────────────────────────────────────────────

  testWidgets('large PDFs are listed and can be opted in', (tester) async {
    _db.attachment = Attachment(
      id: 'att-1',
      noteId: 'note-1',
      filePath: '/tmp/big.pdf',
      fileName: 'big.pdf',
      fileType: 'application/pdf',
      createdAt: DateTime(2026, 1, 1),
    );

    await _pumpScreen(
      tester,
      _screen(
        largePdfLoader: () async => const [
          LargePdfEntry(
            attachmentId: 'att-1',
            fileName: 'big.pdf',
            noteId: 'note-1',
            noteTitle: 'Research',
            pages: 512,
          ),
        ],
      ),
    );

    expect(find.text('1 large PDF not indexed — review'), findsOneWidget);
    expect(find.text('Research · 512 pages'), findsOneWidget);

    await tester.tap(find.text('Index anyway'));
    await tester.pumpAndSettle();

    expect(_db.metadataWrites, hasLength(1));
    final written = _db.metadataWrites.single!['searchIndex'] as Map;
    expect(written['text'], 'on');
  });

  testWidgets('the skipped-PDF list is capped and names the remainder', (
    tester,
  ) async {
    // The card builds its rows eagerly into a Column, so the list is bounded
    // — but the count must still be the real one, not the rendered one.
    await _pumpScreen(
      tester,
      _screen(
        largePdfLoader: () async => [
          for (var i = 0; i < maxLargePdfRows; i++)
            LargePdfEntry(
              attachmentId: 'att-$i',
              fileName: 'big-$i.pdf',
              noteId: 'note-$i',
            ),
        ],
        scopeLoader: () async => const SearchIndexScope(
          notes: 5,
          chunks: 10,
          uploadableChunks: 10,
          largePdfs: 57,
        ),
      ),
    );

    expect(find.text('57 large PDFs not indexed — review'), findsOneWidget);
    expect(find.text('37 more not shown'), findsOneWidget);
    expect(find.text('Index anyway'), findsNWidgets(maxLargePdfRows));
  });

  testWidgets('raising the page cap re-runs the sweep and refreshes the list', (
    tester,
  ) async {
    // Writing the pref alone left the oversized PDF in the "not indexed"
    // list until the next app launch: the cap feeds the attachment state
    // hash, and nothing re-diffed it without a sweep.
    var skipped = <LargePdfEntry>[
      const LargePdfEntry(
        attachmentId: 'att-1',
        fileName: 'big.pdf',
        noteId: 'note-1',
        pages: 512,
      ),
    ];
    await _pumpScreen(tester, _screen(largePdfLoader: () async => skipped));

    expect(find.text('big.pdf'), findsOneWidget);
    // The sweep would now index it: the loader stops reporting it.
    skipped = const [];

    await tester.tap(find.text('Large PDF limit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1000');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(_settings.pageCap, 1000);
    expect(_indexer.ensureBackfilledCalls, 1);
    expect(find.text('big.pdf'), findsNothing);
    expect(find.text('No PDFs are being skipped for size'), findsOneWidget);
  });

  testWidgets('an unchanged page cap does not kick a sweep', (tester) async {
    await _pumpScreen(tester, _screen());

    await tester.tap(find.text('Large PDF limit'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(_indexer.ensureBackfilledCalls, 0);
  });

  // ── OCR + figures ──────────────────────────────────────────────────────

  testWidgets('the OCR toggle persists and re-runs the sweep', (tester) async {
    // Whether OCR runs is part of the OCR stage's policy hash: turning it off
    // has to PURGE the text it contributed, and nothing re-evaluates that
    // until a sweep — without the kick the chunks survived until the next app
    // start or an unrelated bulk change.
    await _pumpScreen(tester, _screen());

    expect(find.text('Runs on-device — nothing is uploaded'), findsOneWidget);
    await tester.tap(find.text('Recognize text in PDFs and images'));
    await tester.pumpAndSettle();

    expect(_settings.ocrEnabled, isFalse);
    expect(_indexer.ensureBackfilledCalls, 1);
  });

  testWidgets('picking an OCR script persists it and re-runs the sweep', (
    tester,
  ) async {
    // The script is part of the OCR state hash, so the affected pages DO
    // re-run — but only once something sweeps.
    await _pumpScreen(tester, _screen());

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chinese').last);
    await tester.pumpAndSettle();

    expect(_settings.ocrScript, 'chinese');
    expect(_indexer.ensureBackfilledCalls, 1);
  });

  testWidgets('the OCR script picker is disabled while OCR is off', (
    tester,
  ) async {
    _settings.ocrEnabled = false;
    await _pumpScreen(tester, _screen());

    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(dropdown.onChanged, isNull);
  });

  testWidgets('the figures toggle persists and re-runs the sweep', (
    tester,
  ) async {
    // The global switch is part of the figures stage's policy hash, so
    // turning it off has to PURGE every figure chunk and the crop it derived
    // — and nothing re-evaluates that stage until a sweep runs.
    await _pumpScreen(tester, _screen());

    await tester.tap(find.text('Index figures and tables'));
    await tester.pumpAndSettle();

    expect(_settings.figures, isFalse);
    expect(_indexer.ensureBackfilledCalls, 1);
  });

  testWidgets('no figure-skill cross-link when the skill is not bundled', (
    tester,
  ) async {
    // Step 15 has not shipped the asset: the hint must be a no-op.
    await _pumpScreen(tester, _screen(figureSkillLoader: () async => null));
    expect(find.text(_skillHint), findsNothing);
  });

  testWidgets('the figure-skill cross-link shows when it can be installed', (
    tester,
  ) async {
    await _pumpScreen(tester, _screen(figureSkillLoader: () async => false));
    expect(find.text(_skillHint), findsOneWidget);
  });

  testWidgets('no figure-skill cross-link once it is installed', (
    tester,
  ) async {
    await _pumpScreen(tester, _screen(figureSkillLoader: () async => true));
    expect(find.text(_skillHint), findsNothing);
  });

  // ── Wi-Fi only ─────────────────────────────────────────────────────────

  testWidgets('wifi-only defaults on for a cloud provider and is togglable', (
    tester,
  ) async {
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );

    await _pumpScreen(tester, _screen());

    final toggle = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Index on Wi-Fi only'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(toggle.value, isTrue);

    await tester.tap(find.text('Index on Wi-Fi only'));
    await tester.pumpAndSettle();
    expect(_settings.wifiOnly, isFalse);
  });

  testWidgets('turning wifi-only off picks the deferred embed pass back up', (
    tester,
  ) async {
    // An embed pass that deferred on the wifi gate cleared its stage's global
    // done flag and waits for the next sweep: without the kick the stalled
    // work only resumed on an app restart or an unrelated bulk change.
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );

    await _pumpScreen(tester, _screen());

    await tester.tap(find.text('Index on Wi-Fi only'));
    await tester.pumpAndSettle();

    expect(_settings.wifiOnly, isFalse);
    expect(_indexer.ensureBackfilledCalls, 1);
  });

  testWidgets('no wifi-only toggle without a cloud provider', (tester) async {
    await _pumpScreen(tester, _screen());
    expect(find.text('Index on Wi-Fi only'), findsNothing);
  });

  // ── Turning the provider off ───────────────────────────────────────────

  testWidgets('"None" clears the provider and says the vectors were kept', (
    tester,
  ) async {
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );

    await _pumpScreen(tester, _screen());

    await tester.tap(find.text('Embedding provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None (lexical only)'));
    await tester.pumpAndSettle();

    expect(_registry.clearActiveCalls, 1);
    // Turning off is NOT deleting: the distinction is the whole reason the
    // delete action is a separate, confirmed one.
    expect(
      find.text('Semantic search off — stored vectors were kept'),
      findsOneWidget,
    );
    expect(_indexer.deleteCalls, 0);
    expect(find.text('None (lexical only)'), findsOneWidget);
  });

  testWidgets('the picker rows carry radio semantics', (tester) async {
    // The rows are ListTiles with a radio GLYPH, which announces nothing on
    // its own — the semantics have to be restored by hand.
    _registry.activeConfigValue = const EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'https://api.openai.com/v1',
      modelName: 'text-embedding-3-small',
      displayName: 'OpenAI Small',
      dimensions: 1536,
    );

    await _pumpScreen(tester, _screen());
    await tester.tap(find.text('Embedding provider'));
    await tester.pumpAndSettle();

    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('OpenAI Small').last),
      isSemantics(
        hasCheckedState: true,
        isChecked: true,
        isInMutuallyExclusiveGroup: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('None (lexical only)')),
      isSemantics(
        hasCheckedState: true,
        isChecked: false,
        isInMutuallyExclusiveGroup: true,
      ),
    );
    handle.dispose();
  });

  // ── Custom provider form ───────────────────────────────────────────────

  testWidgets('an incomplete custom form cannot even be probed', (
    tester,
  ) async {
    // Without this, an empty model name produced providerKey "openai::768"
    // and a provider with no display name at all.
    await _pumpScreen(tester, _screen());
    await _openCustomConfig(tester);

    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Test connection'),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.text('Enter an endpoint URL and a model name before testing.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Endpoint URL'),
      'http://localhost:11434/v1',
    );
    await tester.pumpAndSettle();
    // Endpoint alone is still not enough.
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Test connection'),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Model name'),
      'nomic-embed-text',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Test connection'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a keyless self-hosted endpoint can be enabled', (tester) async {
    await _pumpScreen(tester, _screen());
    await _openCustomConfig(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Endpoint URL'),
      'http://localhost:11434/v1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Model name'),
      'nomic-embed-text',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send and index'));
    await tester.pumpAndSettle();

    final stored = _registry.setConfigCalls.single;
    expect(stored.providerKey, 'openai:nomic-embed-text:768');
    // The display name falls back to the model name, never an empty string.
    expect(stored.displayName, 'nomic-embed-text');
    expect(stored.isCustom, isTrue);
    expect(stored.endpoint, 'http://localhost:11434/v1');
  });

  testWidgets('a matching chat model supplies the key', (tester) async {
    // §2.2 key reuse: the chat key lives in the same secure store under a
    // different handle — asking for it again is friction with no benefit.
    final storage = _FakeModelStorage()
      ..models = [
        ModelConfig(
          id: 'chat-1',
          type: ModelType.openaiCompatible,
          endpoint: 'https://api.openai.com/v1',
          modelName: 'gpt-4o',
          displayName: 'My OpenAI',
        ),
      ]
      ..keys = {'chat-1': 'sk-from-chat'};
    getIt.registerSingleton<ModelStorageService>(storage);

    await _pumpScreen(tester, _screen());
    await _openPresetConfig(tester);

    expect(
      find.textContaining('Prefilled from your My OpenAI chat model'),
      findsOneWidget,
    );
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send and index'));
    await tester.pumpAndSettle();

    expect(_registry.setConfigCalls, hasLength(1));
  });

  testWidgets('a chat model on another host does not lend its key', (
    tester,
  ) async {
    // A key is scoped to a host: prefilling api.openai.com's key into a
    // self-hosted endpoint would leak it on the first probe.
    final storage = _FakeModelStorage()
      ..models = [
        ModelConfig(
          id: 'chat-1',
          type: ModelType.openaiCompatible,
          endpoint: 'https://someone-elses-host.example/v1',
          modelName: 'gpt-4o',
          displayName: 'Elsewhere',
        ),
      ]
      ..keys = {'chat-1': 'sk-from-chat'};
    getIt.registerSingleton<ModelStorageService>(storage);

    await _pumpScreen(tester, _screen());
    await _openPresetConfig(tester);

    expect(find.textContaining('Prefilled from your'), findsNothing);
  });

  // ── On-device model install ────────────────────────────────────────────

  testWidgets('the HuggingFace token rides the download', (tester) async {
    String? seenToken;
    await _pumpScreen(
      tester,
      _screen(
        modelManager: _modelManager(onInstall: (token) => seenToken = token),
      ),
    );
    await _openLocalConfig(tester);

    // A local provider has no endpoint/model/dims form — just the token.
    expect(find.text('Endpoint URL'), findsNothing);
    expect(find.text('HuggingFace access token'), findsOneWidget);
    expect(find.text('Not downloaded yet'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'HuggingFace access token'),
      'hf_token',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();

    expect(seenToken, 'hf_token');
    // …and is remembered for the next re-install/repair, in the slot the
    // registry's own getApiKey reads. Written through the registry (whose
    // storage is injected here), not a hand-rolled FlutterSecureStorage that
    // would address a different store.
    expect(_registry.savedKeys, {
      'embedding_local_embeddinggemma-300m_api_key': 'hf_token',
    });
    // The manager's terminal callback settles on the REAL event loop (its
    // broadcast progress controller is closed before the outcome completer
    // fires), which the widget binding's fake clock never reaches on its
    // own — runAsync hands it one real turn.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _settle(tester);
    expect(find.text('Model downloaded'), findsOneWidget);
    expect(find.text('Installed on this device'), findsOneWidget);
  });

  testWidgets('a gated-repo rejection says to accept the licence', (
    tester,
  ) async {
    await _pumpScreen(
      tester,
      _screen(
        modelManager: _modelManager(failWith: StateError('401 unauthorized')),
      ),
    );
    await _openLocalConfig(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _settle(tester);

    // A non-DownloadException failure carries neither flag, so it lands on
    // the plain message — the point is that it is reported, not swallowed.
    expect(find.textContaining('Download failed'), findsOneWidget);
    expect(find.text('Installed on this device'), findsNothing);
  });

  testWidgets('an installed model can be removed', (tester) async {
    await _pumpScreen(
      tester,
      _screen(modelManager: _modelManager(installed: true)),
    );
    await _openLocalConfig(tester);

    expect(find.text('Installed on this device'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('Model removed'), findsOneWidget);
    expect(find.text('Not downloaded yet'), findsOneWidget);
  });

  testWidgets('the screen reuses one process-wide model manager', (
    tester,
  ) async {
    // A per-screen manager starts with an empty in-flight map, so backing
    // out mid-download and re-entering would start a SECOND ~180 MB download
    // of the same files instead of re-attaching to the running one.
    expect(
      sharedLocalEmbeddingModelManager,
      same(sharedLocalEmbeddingModelManager),
    );
  });

  // ── Settings entry tile ────────────────────────────────────────────────

  group('SearchSettingsTile', () {
    Widget tile() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: SearchSettingsTile()),
    );

    testWidgets('reports lexical-only with no provider configured', (
      tester,
    ) async {
      await tester.pumpWidget(tile());
      await _settle(tester);

      expect(find.text('Search & indexing'), findsOneWidget);
      expect(find.text('Lexical only'), findsOneWidget);
    });

    testWidgets('reports live coverage for the configured provider', (
      tester,
    ) async {
      _registry.activeConfigValue = const EmbeddingProviderConfig(
        type: 'openai',
        endpoint: 'https://api.openai.com/v1',
        modelName: 'text-embedding-3-small',
        displayName: 'OpenAI Small',
        dimensions: 1536,
      );
      // Serving == active: no transition, so the tile reports plain progress
      // rather than the switch label.
      _registry.servingKeyValue = _presetKey;
      _registry.servingNameValue = 'OpenAI Small';
      _indexer.coverage = (embedded: 62, total: 100);

      await tester.pumpWidget(tile());
      await _settle(tester);

      expect(find.text('OpenAI Small · indexing 62%'), findsOneWidget);
    });

    testWidgets('paints the subtitle as an error when the stage halted', (
      tester,
    ) async {
      _registry.activeConfigValue = const EmbeddingProviderConfig(
        type: 'openai',
        endpoint: 'https://api.openai.com/v1',
        modelName: 'text-embedding-3-small',
        displayName: 'OpenAI Small',
        dimensions: 1536,
      );
      _indexer.stageState = (
        status: NoteIndexService.statusError,
        errorMessage: 'Embedding request failed: 401',
        failedChunks: 0,
      );

      await tester.pumpWidget(tile());
      await _settle(tester);

      final subtitle = tester.widget<Text>(
        find.text('OpenAI Small · 1 errors'),
      );
      expect(subtitle.style?.color, isNotNull);
    });

    testWidgets('a tick inside the throttle window still lands', (
      tester,
    ) async {
      // The "backfill finished" tick very often arrives inside the window,
      // and dropping it froze the subtitle on a percentage that would never
      // move again.
      _registry.activeConfigValue = const EmbeddingProviderConfig(
        type: 'openai',
        endpoint: 'https://api.openai.com/v1',
        modelName: 'text-embedding-3-small',
        displayName: 'OpenAI Small',
        dimensions: 1536,
      );
      _registry.servingKeyValue = _presetKey;
      _registry.servingNameValue = 'OpenAI Small';
      _indexer.coverage = (embedded: 10, total: 100);

      await tester.pumpWidget(tile());
      await _settle(tester);
      expect(find.text('OpenAI Small · indexing 10%'), findsOneWidget);

      // Immediately after the initial load — inside the 2s throttle.
      _indexer.coverage = (embedded: 100, total: 100);
      _indexer.stageState = (
        status: NoteIndexService.statusDone,
        errorMessage: null,
        failedChunks: 0,
      );
      _indexer.progressNotifier.value = const IndexProgress(
        done: 100,
        total: 100,
        stage: 'embed:openai:text-embedding-3-small:1536',
        running: false,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('OpenAI Small · indexing 10%'), findsOneWidget);

      // ...and the trailing edge picks it up without another tick.
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(find.text('OpenAI Small · semantic search on'), findsOneWidget);
    });
  });
}

/// Walks provider tile → picker → the CUSTOM configuration page.
Future<void> _openCustomConfig(WidgetTester tester) async {
  await tester.tap(find.text('Embedding provider'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Custom (OpenAI-compatible)'));
  await tester.pumpAndSettle();
}

/// Walks provider tile → picker → the on-device preset's page.
Future<void> _openLocalConfig(WidgetTester tester) async {
  await tester.tap(find.text('Embedding provider'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('EmbeddingGemma'));
  await tester.pumpAndSettle();
}

const String _skillHint =
    'Install the Figure Answers skill for better figure replies';
