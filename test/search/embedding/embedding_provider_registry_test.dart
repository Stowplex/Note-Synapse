import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider_registry.dart';
import 'package:note_synapse/services/search/embedding/gemini_embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/openai_embedding_provider.dart';

/// Secure storage whose reads are slow (writes/deletes stay fast) — lets
/// tests interleave a slow [EmbeddingProviderRegistry.initialize] with a
/// fast [EmbeddingProviderRegistry.setActiveConfig].
class SlowReadSecureStorage extends FlutterSecureStorage {
  const SlowReadSecureStorage();

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

/// Secure storage that records the writes it receives, so a test can prove
/// [EmbeddingProviderRegistry.saveApiKey] goes through the registry's
/// INJECTED storage rather than a hand-rolled FlutterSecureStorage.
class RecordingSecureStorage extends FlutterSecureStorage {
  RecordingSecureStorage(this.writes);

  final List<({String key, String? value})> writes;

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
    writes.add((key: key, value: value));
    return super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  const geminiConfig = EmbeddingProviderConfig(
    type: 'gemini',
    endpoint: 'https://generativelanguage.googleapis.com/v1beta',
    modelName: 'gemini-embedding-001',
    displayName: 'Gemini Embedding',
    dimensions: 768,
  );

  const customConfig = EmbeddingProviderConfig(
    type: 'openai',
    endpoint: 'http://localhost:8080/v1',
    modelName: 'bge-m3',
    displayName: 'Custom (OpenAI-compatible)',
    dimensions: 768,
    isCustom: true,
  );

  http.Response openAiResponse(List<double> vector) => http.Response(
    jsonEncode({
      'data': [
        {'index': 0, 'embedding': vector},
      ],
    }),
    200,
  );

  group('active provider resolution', () {
    test('active is null with no persisted config', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.initialize();
      expect(registry.active, isNull);
      expect(registry.activeConfig, isNull);
    });

    test('setActiveConfig persists config + key and builds provider', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(geminiConfig, apiKey: 'secret-key');

      expect(registry.active, isA<GeminiEmbeddingProvider>());
      expect(registry.active!.providerKey, 'gemini:gemini-embedding-001:768');
      expect(registry.activeConfig?.apiKey, 'secret-key');
      expect(await registry.active!.isReady(), isTrue);

      // A fresh registry instance re-resolves from SharedPreferences +
      // secure storage (mirrors ModelStorageService persistence).
      final reloaded = EmbeddingProviderRegistry();
      await reloaded.initialize();
      expect(reloaded.active, isA<GeminiEmbeddingProvider>());
      expect(reloaded.activeConfig?.apiKey, 'secret-key');
      // The API key never lands in SharedPreferences JSON.
      final prefs = await SharedPreferences.getInstance();
      final storedJson = prefs.getString(
        EmbeddingProviderRegistry.activeConfigPrefsKey,
      )!;
      expect(storedJson.contains('secret-key'), isFalse);
    });

    test(
      'custom OpenAI-compatible config (no preset, keyless) works',
      () async {
        final registry = EmbeddingProviderRegistry();
        await registry.setActiveConfig(customConfig);

        expect(registry.active, isA<OpenAIEmbeddingProvider>());
        expect(registry.activeConfig?.isCustom, isTrue);
        expect(registry.activeConfig?.apiKey, isNull);
        expect(await registry.active!.isReady(), isTrue);
      },
    );

    test(
      'clearActiveConfig switches to none and keeps the stored key',
      () async {
        final registry = EmbeddingProviderRegistry();
        await registry.setActiveConfig(geminiConfig, apiKey: 'keep-me');
        await registry.clearActiveConfig();

        expect(registry.active, isNull);
        expect(await registry.getApiKey(geminiConfig), 'keep-me');

        // Re-enabling the same provider reuses the stored key.
        await registry.setActiveConfig(geminiConfig);
        expect(registry.activeConfig?.apiKey, 'keep-me');
      },
    );

    test('clearActiveConfig(deleteApiKey: true) removes the key', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(geminiConfig, apiKey: 'gone');
      await registry.clearActiveConfig(deleteApiKey: true);
      expect(await registry.getApiKey(geminiConfig), isNull);
    });

    test('saveApiKey stores a key WITHOUT activating the provider, in the '
        'slot getApiKey reads', () async {
      final registry = EmbeddingProviderRegistry();
      // The gated-download flow: the token is needed before the provider can
      // be enabled, so nothing may be activated by storing it.
      await registry.saveApiKey(geminiConfig, 'hf-token');

      expect(registry.active, isNull);
      expect(registry.activeConfig, isNull);
      expect(await registry.getApiKey(geminiConfig), 'hf-token');

      // Enabling the provider later resolves the stored key.
      await registry.setActiveConfig(geminiConfig);
      expect(registry.activeConfig?.apiKey, 'hf-token');
    });

    test(
      'saveApiKey uses the registry\'s own storage and key format',
      () async {
        final writes = <({String key, String? value})>[];
        final registry = EmbeddingProviderRegistry(
          storage: RecordingSecureStorage(writes),
        );
        final hostA = customConfig.copyWith(endpoint: 'https://host-a.example');
        await registry.saveApiKey(hostA, 'host-a-secret');

        // Injected storage, not a private FlutterSecureStorage instance.
        expect(writes, hasLength(1));
        // Endpoint-scoped storageId scheme (a hand-written key would have to
        // reproduce the endpoint digest to hit the same slot).
        expect(writes.single.key, '${hostA.storageId}_api_key');
        expect(writes.single.value, 'host-a-secret');

        // The same-model config on another host keeps its own slot.
        final hostB = customConfig.copyWith(endpoint: 'https://host-b.example');
        expect(await registry.getApiKey(hostB), isNull);
      },
    );

    test('custom configs for the same model at different endpoints get '
        'distinct storage ids', () {
      final hostA = customConfig.copyWith(endpoint: 'https://host-a.example');
      final hostB = customConfig.copyWith(endpoint: 'https://host-b.example');

      expect(hostA.storageId, isNot(hostB.storageId));
      // Cosmetic endpoint variants still map to the same identity.
      final hostASlash = customConfig.copyWith(
        endpoint: 'https://host-a.example/',
      );
      expect(hostASlash.storageId, hostA.storageId);
      // Preset Gemini ids stay endpoint-less and stable.
      expect(geminiConfig.storageId, 'embedding_gemini_gemini-embedding-001');
    });

    test(
      'keyless config on host B never inherits host A\'s stored key',
      () async {
        // Same model name, different endpoints: without endpoint-scoped
        // storage ids, host A's Bearer key would leak to host B.
        final hostA = customConfig.copyWith(endpoint: 'https://host-a.example');
        final hostB = customConfig.copyWith(endpoint: 'https://host-b.example');

        final requests = <({Uri url, String? auth})>[];
        final registry = EmbeddingProviderRegistry(
          httpPost: (url, {headers, body}) async {
            requests.add((url: url, auth: headers?['Authorization']));
            return openAiResponse(List<double>.filled(768, 0.1));
          },
        );

        await registry.setActiveConfig(hostA, apiKey: 'host-a-secret');
        await registry.active!.embedQuery('q');
        expect(requests.last.auth, 'Bearer host-a-secret');

        // Switch to a keyless config for the SAME model on another host.
        await registry.setActiveConfig(hostB);
        expect(registry.activeConfig?.apiKey, isNull);
        await registry.active!.embedQuery('q');
        expect(requests.last.url.host, 'host-b.example');
        expect(requests.last.auth, isNull);
      },
    );

    test('mutating operations are serialized: a slow initialize cannot '
        'clobber a fresh setActiveConfig', () async {
      // Seed a persisted gemini config + key for initialize to load.
      final seeder = EmbeddingProviderRegistry();
      await seeder.setActiveConfig(geminiConfig, apiKey: 'seed');

      // Reads are slow: an un-serialized initialize would resolve its API
      // key AFTER the (key-carrying, hence read-free) setActiveConfig
      // completes and overwrite the fresher state with the stale config.
      final registry = EmbeddingProviderRegistry(
        storage: const SlowReadSecureStorage(),
      );
      final init = registry.initialize();
      final set = registry.setActiveConfig(customConfig, apiKey: 'fresh');
      await Future.wait([init, set]);

      expect(registry.activeConfig?.modelName, customConfig.modelName);
      expect(registry.activeConfig?.apiKey, 'fresh');
      expect(registry.active, isA<OpenAIEmbeddingProvider>());
    });

    test('clearActiveConfig(deleteApiKey: true) on an uninitialized '
        'registry still deletes the persisted key', () async {
      final first = EmbeddingProviderRegistry();
      await first.setActiveConfig(geminiConfig, apiKey: 'orphan');

      // Fresh instance, initialize() never called: _activeConfig is null,
      // but the persisted config must still be loaded so its key dies.
      final uninitialized = EmbeddingProviderRegistry();
      await uninitialized.clearActiveConfig(deleteApiKey: true);

      expect(await uninitialized.getApiKey(geminiConfig), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(EmbeddingProviderRegistry.activeConfigPrefsKey),
        isNull,
      );
    });

    test('unknown provider type yields null provider', () {
      final registry = EmbeddingProviderRegistry();
      final provider = registry.buildProvider(
        const EmbeddingProviderConfig(
          type: 'martian',
          modelName: 'x',
          displayName: 'x',
          dimensions: 1,
        ),
      );
      expect(provider, isNull);
    });
  });

  group('testConnection', () {
    test('matching dimensions probe succeeds', () async {
      final registry = EmbeddingProviderRegistry(
        httpPost: (url, {headers, body}) async =>
            openAiResponse(List<double>.filled(768, 0.1)),
      );

      final result = await registry.testConnection(customConfig);

      expect(result.ok, isTrue);
      expect(result.detectedDimensions, 768);
      expect(result.dimensionsMatched, isTrue);
      expect(result.correctedConfig?.dimensions, 768);
    });

    test('dims mismatch auto-detects and returns corrected config', () async {
      // User typed 768 but the server actually returns 1024-dim vectors.
      final registry = EmbeddingProviderRegistry(
        httpPost: (url, {headers, body}) async =>
            openAiResponse(List<double>.filled(1024, 0.1)),
      );

      final result = await registry.testConnection(customConfig);

      expect(result.ok, isTrue);
      expect(result.detectedDimensions, 1024);
      expect(result.dimensionsMatched, isFalse);
      expect(result.correctedConfig?.dimensions, 1024);
      // Correction changes the providerKey (row-level invalidation key).
      expect(result.correctedConfig?.providerKey, 'openai:bge-m3:1024');
    });

    test('auth failure surfaces isAuthError', () async {
      final registry = EmbeddingProviderRegistry(
        httpPost: (url, {headers, body}) async =>
            http.Response('{"error": "bad key"}', 401),
      );

      final result = await registry.testConnection(
        geminiConfig,
        apiKey: 'wrong',
      );

      expect(result.ok, isFalse);
      expect(result.isAuthError, isTrue);
      expect(result.errorMessage, isNotNull);
    });

    test('transient failure surfaces isTransient', () async {
      final registry = EmbeddingProviderRegistry(
        httpPost: (url, {headers, body}) async => http.Response('busy', 429),
      );

      final result = await registry.testConnection(customConfig);

      expect(result.ok, isFalse);
      expect(result.isTransient, isTrue);
      expect(result.isAuthError, isFalse);
    });

    test('probe uses the freshly typed key over the stored one', () async {
      String? seenAuth;
      final registry = EmbeddingProviderRegistry(
        httpPost: (url, {headers, body}) async {
          seenAuth = headers?['Authorization'];
          return openAiResponse(List<double>.filled(768, 0.1));
        },
      );
      await registry.setActiveConfig(customConfig, apiKey: 'stored');

      await registry.testConnection(customConfig, apiKey: 'typed');

      expect(seenAuth, 'Bearer typed');
    });
  });

  // Provider-switch lifecycle (plan §2.3): the SERVING key lags the ACTIVE
  // key across a switch, and both survive a restart.
  group('serving key state machine', () {
    const configB = EmbeddingProviderConfig(
      type: 'openai',
      endpoint: 'http://localhost:8080/v1',
      modelName: 'other-model',
      displayName: 'Other',
      dimensions: 1024,
      isCustom: true,
    );

    test('serving stays null until the indexer promotes', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(geminiConfig, apiKey: 'k');
      expect(registry.activeConfig!.providerKey, isNotNull);
      expect(registry.servingProviderKey, isNull);
      expect(registry.transitionState.inTransition, isTrue);

      final promotion = await registry.promoteActiveToServing(
        geminiConfig.providerKey,
      );
      expect(promotion.promoted, isTrue);
      expect(promotion.previousKey, isNull);
      expect(registry.servingProviderKey, geminiConfig.providerKey);
      expect(registry.servingProvider, isNotNull);
      expect(registry.transitionState.inTransition, isFalse);
    });

    test(
      'A keeps serving while B is the active (backfilling) provider',
      () async {
        final registry = EmbeddingProviderRegistry();
        await registry.setActiveConfig(geminiConfig, apiKey: 'k');
        await registry.promoteActiveToServing(geminiConfig.providerKey);

        await registry.setActiveConfig(configB);
        expect(registry.activeConfig!.providerKey, configB.providerKey);
        expect(registry.servingProviderKey, geminiConfig.providerKey);
        final state = registry.transitionState;
        expect(state.inTransition, isTrue);
        expect(state.servingDisplayName, geminiConfig.displayName);
        expect(state.activeDisplayName, configB.displayName);

        // Promotion returns the superseded key so the caller can GC its rows.
        final promotion = await registry.promoteActiveToServing(
          configB.providerKey,
        );
        expect(promotion.promoted, isTrue);
        expect(promotion.previousKey, geminiConfig.providerKey);
        expect(registry.servingProviderKey, configB.providerKey);
      },
    );

    test(
      'a mid-transition restart resumes with A serving and B active',
      () async {
        final registry = EmbeddingProviderRegistry();
        await registry.setActiveConfig(geminiConfig, apiKey: 'k');
        await registry.promoteActiveToServing(geminiConfig.providerKey);
        await registry.setActiveConfig(configB);

        final reloaded = EmbeddingProviderRegistry();
        await reloaded.initialize();
        expect(reloaded.activeConfig!.providerKey, configB.providerKey);
        expect(reloaded.servingProviderKey, geminiConfig.providerKey);
        expect(reloaded.servingProvider, isNotNull);
        expect(reloaded.transitionState.inTransition, isTrue);
      },
    );

    test(
      're-saving the serving config (key fix) keeps serving aligned',
      () async {
        final registry = EmbeddingProviderRegistry();
        await registry.setActiveConfig(geminiConfig, apiKey: 'k');
        await registry.promoteActiveToServing(geminiConfig.providerKey);

        await registry.setActiveConfig(geminiConfig, apiKey: 'fixed-key');
        expect(registry.servingProviderKey, geminiConfig.providerKey);
        expect(registry.servingConfig?.apiKey, 'fixed-key');
        expect(identical(registry.servingProvider, registry.active), isTrue);
        expect(registry.transitionState.inTransition, isFalse);

        // And it survives a restart aligned.
        final reloaded = EmbeddingProviderRegistry();
        await reloaded.initialize();
        expect(reloaded.servingProviderKey, geminiConfig.providerKey);
        expect(identical(reloaded.servingProvider, reloaded.active), isTrue);
      },
    );

    test(
      'revokeServing degrades to lexical without touching the target',
      () async {
        final registry = EmbeddingProviderRegistry();
        await registry.setActiveConfig(geminiConfig, apiKey: 'k');
        await registry.promoteActiveToServing(geminiConfig.providerKey);
        await registry.setActiveConfig(configB);

        await registry.revokeServing();
        expect(registry.servingProviderKey, isNull);
        expect(registry.servingProvider, isNull);
        expect(registry.activeConfig!.providerKey, configB.providerKey);

        final reloaded = EmbeddingProviderRegistry();
        await reloaded.initialize();
        expect(reloaded.servingProviderKey, isNull);
      },
    );

    test('clearActiveConfig (None) clears the serving key too', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(geminiConfig, apiKey: 'k');
      await registry.promoteActiveToServing(geminiConfig.providerKey);

      await registry.clearActiveConfig();
      expect(registry.active, isNull);
      expect(registry.servingProvider, isNull);
      expect(registry.servingProviderKey, isNull);

      final reloaded = EmbeddingProviderRegistry();
      await reloaded.initialize();
      expect(reloaded.servingProviderKey, isNull);
    });

    test('promoting with no active provider is a no-op', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.initialize();
      final promotion = await registry.promoteActiveToServing('any:key:1');
      expect(promotion.promoted, isFalse);
      expect(registry.servingProviderKey, isNull);
    });

    test('a pass that finished for a superseded key never promotes', () async {
      const configC = EmbeddingProviderConfig(
        type: 'openai',
        endpoint: 'http://localhost:8080/v1',
        modelName: 'third-model',
        displayName: 'Third',
        dimensions: 512,
        isCustom: true,
      );
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(geminiConfig, apiKey: 'k');
      await registry.promoteActiveToServing(geminiConfig.providerKey);

      // The user switches A → B, then B → C while B's pass is still running.
      await registry.setActiveConfig(configB);
      await registry.setActiveConfig(configC);

      // B's pass finishes: C has no vectors yet, so nothing may change.
      final promotion = await registry.promoteActiveToServing(
        configB.providerKey,
      );
      expect(promotion.promoted, isFalse);
      expect(promotion.previousKey, isNull);
      expect(registry.servingProviderKey, geminiConfig.providerKey);

      // C's own pass then promotes normally, superseding A.
      final cPromotion = await registry.promoteActiveToServing(
        configC.providerKey,
      );
      expect(cPromotion.promoted, isTrue);
      expect(cPromotion.previousKey, geminiConfig.providerKey);
      expect(registry.servingProviderKey, configC.providerKey);
    });

    test(
      'revokeServing remembers the key and blocks its re-promotion',
      () async {
        final registry = EmbeddingProviderRegistry();
        await registry.setActiveConfig(geminiConfig, apiKey: 'k');
        await registry.promoteActiveToServing(geminiConfig.providerKey);

        // "Stop using A now" while A is STILL the active provider.
        await registry.revokeServing();
        expect(registry.servingProviderKey, isNull);
        expect(registry.revokedServingKey, geminiConfig.providerKey);
        expect(registry.isServingRevoked(geminiConfig.providerKey), isTrue);

        final promotion = await registry.promoteActiveToServing(
          geminiConfig.providerKey,
        );
        expect(promotion.promoted, isFalse);
        expect(registry.servingProviderKey, isNull);

        // And it survives a restart.
        final reloaded = EmbeddingProviderRegistry();
        await reloaded.initialize();
        expect(reloaded.servingProviderKey, isNull);
        expect(reloaded.revokedServingKey, geminiConfig.providerKey);
        expect(reloaded.transitionState.activeRevoked, isTrue);
        final afterRestart = await reloaded.promoteActiveToServing(
          geminiConfig.providerKey,
        );
        expect(afterRestart.promoted, isFalse);
      },
    );

    test('re-selecting a revoked provider lifts the revocation', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(geminiConfig, apiKey: 'k');
      await registry.promoteActiveToServing(geminiConfig.providerKey);
      await registry.revokeServing();

      await registry.setActiveConfig(geminiConfig);
      expect(registry.revokedServingKey, isNull);
      final promotion = await registry.promoteActiveToServing(
        geminiConfig.providerKey,
      );
      expect(promotion.promoted, isTrue);
      expect(registry.servingProviderKey, geminiConfig.providerKey);

      final reloaded = EmbeddingProviderRegistry();
      await reloaded.initialize();
      expect(reloaded.revokedServingKey, isNull);
    });

    test('revoking A does not block a switch to B', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(geminiConfig, apiKey: 'k');
      await registry.promoteActiveToServing(geminiConfig.providerKey);
      await registry.revokeServing();
      await registry.setActiveConfig(configB);

      final promotion = await registry.promoteActiveToServing(
        configB.providerKey,
      );
      expect(promotion.promoted, isTrue);
      expect(registry.servingProviderKey, configB.providerKey);
      // A's revocation is remembered until A is picked again.
      expect(registry.revokedServingKey, geminiConfig.providerKey);
    });

    test('clearActiveConfig (None) resets the revoked marker too', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(geminiConfig, apiKey: 'k');
      await registry.promoteActiveToServing(geminiConfig.providerKey);
      await registry.revokeServing();

      await registry.clearActiveConfig();
      expect(registry.revokedServingKey, isNull);
      final reloaded = EmbeddingProviderRegistry();
      await reloaded.initialize();
      expect(reloaded.revokedServingKey, isNull);
    });

    test('ensureInitialized runs initialize once and does not clobber a '
        'later setActiveConfig', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.ensureInitialized();
      await registry.setActiveConfig(configB);
      await registry.ensureInitialized();
      expect(registry.activeConfig!.providerKey, configB.providerKey);
    });
  });
}
