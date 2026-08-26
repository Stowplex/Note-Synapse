import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart' show EmbeddingModel, TaskType;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider_registry.dart';
import 'package:note_synapse/services/search/embedding/local_embedding_provider.dart';

/// Fake native model for the activateModel seam: canned vectors, an
/// arm-once failure to simulate an externally closed plugin singleton, and
/// a close counter.
class FakeEmbeddingModel implements EmbeddingModel {
  final List<List<double>> Function(List<String> texts) vectorsFor;

  /// When set, the next generate call throws this once (mimics the plugin
  /// singleton having been closed under us — StateError until re-init).
  Object? throwOnce;
  int closeCalls = 0;

  FakeEmbeddingModel(this.vectorsFor);

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async {
    return (await generateEmbeddings([text], taskType: taskType)).first;
  }

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async {
    final failure = throwOnce;
    if (failure != null) {
      throwOnce = null;
      // ignore: only_throw_errors
      throw failure;
    }
    return vectorsFor(texts);
  }

  @override
  Future<int> getDimension() async => 768;

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

/// LocalEmbeddingProvider that counts [dispose] calls (the registry's probe
/// cleanup is otherwise unobservable through the seams).
class SpyLocalProvider extends LocalEmbeddingProvider {
  int disposeCalls = 0;

  SpyLocalProvider(super.config, {super.installedCheck, super.embedFn});

  @override
  Future<void> dispose() {
    disposeCalls++;
    return super.dispose();
  }
}

/// Registry that builds [SpyLocalProvider]s so tests can observe which
/// providers (active vs throwaway probe) get disposed.
class SpyRegistry extends EmbeddingProviderRegistry {
  final LocalEmbedderInstalledCheck installedCheck;
  final LocalEmbedFn embedFn;
  final List<SpyLocalProvider> localProviders = [];

  SpyRegistry({required this.installedCheck, required this.embedFn})
    : super(localInstalledCheck: installedCheck, localEmbedFn: embedFn);

  @override
  EmbeddingProvider? buildProvider(EmbeddingProviderConfig config) {
    if (config.type == 'local') {
      final spy = SpyLocalProvider(
        config,
        installedCheck: installedCheck,
        embedFn: embedFn,
      );
      localProviders.add(spy);
      return spy;
    }
    return super.buildProvider(config);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const modelUrl =
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/'
      'main/embeddinggemma-300M_seq512_mixed-precision.tflite';
  const tokenizerUrl =
      'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/'
      'main/sentencepiece.model';

  const localConfig = EmbeddingProviderConfig(
    type: 'local',
    modelName: 'embeddinggemma-300m',
    displayName: 'EmbeddingGemma (on-device)',
    dimensions: 768,
    modelUrl: modelUrl,
    tokenizerUrl: tokenizerUrl,
  );

  /// Captures every embed call the provider makes and returns [vectors]
  /// (cycled per input when a call has more texts than provided vectors).
  ({LocalEmbedFn fn, List<({List<String> texts, TaskType taskType})> calls})
  recordingEmbedFn(List<List<double>> vectors) {
    final calls = <({List<String> texts, TaskType taskType})>[];
    Future<List<List<double>>> fn(List<String> texts, TaskType taskType) async {
      calls.add((texts: texts, taskType: taskType));
      return List.generate(texts.length, (i) => vectors[i % vectors.length]);
    }

    return (fn: fn, calls: calls);
  }

  group('LocalEmbeddingProvider', () {
    test('providerKey follows "local:{model}:{dims}"', () {
      final provider = LocalEmbeddingProvider(localConfig);
      expect(provider.providerKey, 'local:embeddinggemma-300m:768');
      expect(provider.displayName, 'EmbeddingGemma (on-device)');
      expect(provider.dimensions, 768);
      expect(provider.supportsImages, isFalse);
      expect(provider.maxBatchSize, 8);
    });

    test('filenames derive from URL basenames (installer convention)', () {
      expect(
        LocalEmbeddingProvider.modelFilenameFor(localConfig),
        'embeddinggemma-300M_seq512_mixed-precision.tflite',
      );
      expect(
        LocalEmbeddingProvider.tokenizerFilenameFor(localConfig),
        'sentencepiece.model',
      );
      expect(
        LocalEmbeddingProvider.modelFilenameFor(
          localConfig.copyWith(modelUrl: ''),
        ),
        isNull,
      );
    });

    test('config JSON round-trip preserves the two download URLs', () {
      final restored = EmbeddingProviderConfig.fromJson(localConfig.toJson());
      expect(restored.modelUrl, modelUrl);
      expect(restored.tokenizerUrl, tokenizerUrl);
      expect(restored.providerKey, localConfig.providerKey);
      // Local storage id stays endpoint-less (holds the HF token slot).
      expect(localConfig.storageId, 'embedding_local_embeddinggemma-300m');
    });

    test('embedDocuments routes taskType retrievalDocument, embedQuery '
        'retrievalQuery', () async {
      final recorder = recordingEmbedFn([List<double>.filled(4, 0.5)]);
      final provider = LocalEmbeddingProvider(
        localConfig.copyWith(dimensions: 4),
        installedCheck: (_) async => true,
        embedFn: recorder.fn,
      );

      await provider.embedDocuments(const [
        EmbeddingInput.text('doc one'),
        EmbeddingInput.text('doc two'),
      ]);
      await provider.embedQuery('a query');

      expect(recorder.calls, hasLength(2));
      expect(recorder.calls[0].texts, ['doc one', 'doc two']);
      expect(recorder.calls[0].taskType, TaskType.retrievalDocument);
      expect(recorder.calls[1].texts, ['a query']);
      expect(recorder.calls[1].taskType, TaskType.retrievalQuery);
    });

    test('outputs are L2-normalized (documents and query)', () async {
      final recorder = recordingEmbedFn([
        [3.0, 4.0],
      ]);
      final provider = LocalEmbeddingProvider(
        localConfig.copyWith(dimensions: 2),
        installedCheck: (_) async => true,
        embedFn: recorder.fn,
      );

      final docs = await provider.embedDocuments(const [
        EmbeddingInput.text('d'),
      ]);
      expect(docs.single, isA<Float32List>());
      expect(docs.single[0], closeTo(0.6, 1e-6));
      expect(docs.single[1], closeTo(0.8, 1e-6));

      final query = await provider.embedQuery('q');
      expect(query[0], closeTo(0.6, 1e-6));
      expect(query[1], closeTo(0.8, 1e-6));
    });

    test('image input throws a permanent EmbeddingProviderException without '
        'touching the model', () async {
      final recorder = recordingEmbedFn([
        [1.0],
      ]);
      final provider = LocalEmbeddingProvider(
        localConfig,
        installedCheck: (_) async => true,
        embedFn: recorder.fn,
      );

      await expectLater(
        provider.embedDocuments([
          const EmbeddingInput.text('fine'),
          EmbeddingInput.image(Uint8List.fromList([1, 2, 3]), 'image/png'),
        ]),
        throwsA(
          isA<EmbeddingProviderException>()
              .having((e) => e.isAuthError, 'isAuthError', isFalse)
              .having((e) => e.isTransient, 'isTransient', isFalse)
              .having((e) => e.isNotInstalled, 'isNotInstalled', isFalse)
              .having((e) => e.message, 'message', contains('image')),
        ),
      );
      expect(recorder.calls, isEmpty);
    });

    test('over-cap batch throws ArgumentError; at-cap batch passes', () async {
      final recorder = recordingEmbedFn([
        [1.0, 0.0],
      ]);
      final provider = LocalEmbeddingProvider(
        localConfig.copyWith(dimensions: 2),
        installedCheck: (_) async => true,
        embedFn: recorder.fn,
      );

      final overCap = List.generate(
        provider.maxBatchSize + 1,
        (i) => EmbeddingInput.text('t$i'),
      );
      await expectLater(
        provider.embedDocuments(overCap),
        throwsA(isA<ArgumentError>()),
      );
      expect(recorder.calls, isEmpty);

      final atCap = List.generate(
        provider.maxBatchSize,
        (i) => EmbeddingInput.text('t$i'),
      );
      final vectors = await provider.embedDocuments(atCap);
      expect(vectors, hasLength(provider.maxBatchSize));
    });

    test('empty input embeds nothing', () async {
      final recorder = recordingEmbedFn([
        [1.0],
      ]);
      final provider = LocalEmbeddingProvider(
        localConfig,
        installedCheck: (_) async => true,
        embedFn: recorder.fn,
      );
      expect(await provider.embedDocuments(const []), isEmpty);
      expect(recorder.calls, isEmpty);
    });

    test(
      'vector-count mismatch surfaces as EmbeddingProviderException',
      () async {
        final provider = LocalEmbeddingProvider(
          localConfig.copyWith(dimensions: 2),
          installedCheck: (_) async => true,
          embedFn: (texts, taskType) async => [
            [1.0, 0.0],
          ],
        );
        await expectLater(
          provider.embedDocuments(const [
            EmbeddingInput.text('a'),
            EmbeddingInput.text('b'),
          ]),
          throwsA(isA<EmbeddingProviderException>()),
        );
      },
    );

    test(
      'not installed: isReady false, embeds fail with isNotInstalled',
      () async {
        final provider = LocalEmbeddingProvider(
          localConfig,
          installedCheck: (_) async => false,
        );

        expect(await provider.isReady(), isFalse);
        await expectLater(
          provider.embedQuery('q'),
          throwsA(
            isA<EmbeddingProviderException>()
                .having((e) => e.isNotInstalled, 'isNotInstalled', isTrue)
                .having((e) => e.isAuthError, 'isAuthError', isFalse)
                .having((e) => e.isTransient, 'isTransient', isFalse),
          ),
        );
      },
    );

    test('default installed-check degrades to false when the flutter_gemma '
        'platform channel is unavailable (no seam injected)', () async {
      final provider = LocalEmbeddingProvider(localConfig);
      expect(await provider.isReady(), isFalse);
    });

    test('dispose before any embed is a safe no-op', () async {
      final provider = LocalEmbeddingProvider(localConfig);
      await provider.dispose();
      await provider.dispose();
    });

    test(
      'percent-encoded URL basenames stay encoded (matches '
      'EmbeddingInstallationBuilder\'s path.basename(Uri.path) derivation)',
      () {
        final encoded = localConfig.copyWith(
          modelUrl: 'https://example.com/models/my%20model%2Bv2.tflite',
        );
        // Uri.pathSegments would decode this to "my model+v2.tflite" and the
        // installed-check/uninstall would then miss the file the installer
        // actually wrote.
        expect(
          LocalEmbeddingProvider.modelFilenameFor(encoded),
          'my%20model%2Bv2.tflite',
        );
      },
    );

    test('off-size vectors throw a permanent dims mismatch naming both '
        'sizes', () async {
      final provider = LocalEmbeddingProvider(
        localConfig, // promises 768 dims
        installedCheck: (_) async => true,
        embedFn: (texts, taskType) async => [
          [1.0, 0.0, 0.0],
        ],
      );

      await expectLater(
        provider.embedQuery('q'),
        throwsA(
          isA<EmbeddingProviderException>()
              .having((e) => e.detectedDimensions, 'detectedDimensions', 3)
              .having((e) => e.isAuthError, 'isAuthError', isFalse)
              .having((e) => e.isTransient, 'isTransient', isFalse)
              .having((e) => e.isNotInstalled, 'isNotInstalled', isFalse)
              .having((e) => e.message, 'message', contains('3'))
              .having((e) => e.message, 'message', contains('768')),
        ),
      );
    });
  });

  group('LocalEmbeddingProvider model lifecycle (activateModel seam)', () {
    List<List<double>> cannedVectors(List<String> texts) => [
      for (final _ in texts) List<double>.filled(768, 0.1),
    ];

    test('embed failure clears the cached model so the next embed '
        're-initializes (self-heal after external close)', () async {
      var activations = 0;
      final model = FakeEmbeddingModel(cannedVectors);
      final provider = LocalEmbeddingProvider(
        localConfig,
        installedCheck: (_) async => true,
        activateModel: (_) async {
          activations++;
          return model;
        },
      );

      // First embed lazily initializes and succeeds.
      expect(await provider.embedQuery('q'), hasLength(768));
      expect(activations, 1);

      // Simulate the plugin-level singleton being closed externally (probe
      // dispose, uninstall): the cached model throws StateError.
      model.throwOnce = StateError('Embedding model is closed');
      await expectLater(
        provider.embedQuery('q'),
        throwsA(isA<EmbeddingProviderException>()),
      );

      // Self-heal: the cache was cleared, so this embed re-activates
      // instead of failing forever on the dead cached instance.
      expect(await provider.embedQuery('q'), hasLength(768));
      expect(activations, 2);
    });

    test('init failure clears the cache so the next embed retries '
        'initialization', () async {
      var activations = 0;
      final model = FakeEmbeddingModel(cannedVectors);
      final provider = LocalEmbeddingProvider(
        localConfig,
        installedCheck: (_) async => true,
        activateModel: (_) async {
          activations++;
          if (activations == 1) throw StateError('native init failed');
          return model;
        },
      );

      await expectLater(
        provider.embedQuery('q'),
        throwsA(isA<EmbeddingProviderException>()),
      );
      expect(await provider.embedQuery('q'), hasLength(768));
      expect(activations, 2);
    });

    test(
      'files vanishing between installed-check and activation yield '
      'isNotInstalled without touching the installer (TOCTOU guard)',
      () async {
        var checks = 0;
        var activations = 0;
        final provider = LocalEmbeddingProvider(
          localConfig,
          // First check (embed entry) sees the files; the re-check right
          // before activation sees them gone (concurrent uninstall).
          installedCheck: (_) async => ++checks == 1,
          activateModel: (_) async {
            activations++;
            return FakeEmbeddingModel(cannedVectors);
          },
        );

        await expectLater(
          provider.embedQuery('q'),
          throwsA(
            isA<EmbeddingProviderException>().having(
              (e) => e.isNotInstalled,
              'isNotInstalled',
              isTrue,
            ),
          ),
        );
        expect(checks, 2);
        expect(activations, 0);
      },
    );

    test('dispose closes the model created by activateModel', () async {
      final model = FakeEmbeddingModel(cannedVectors);
      final provider = LocalEmbeddingProvider(
        localConfig,
        installedCheck: (_) async => true,
        activateModel: (_) async => model,
      );

      await provider.embedQuery('q');
      await provider.dispose();
      expect(model.closeCalls, 1);
    });
  });

  group('registry integration', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('local config resolves to LocalEmbeddingProvider', () async {
      final registry = EmbeddingProviderRegistry();
      await registry.setActiveConfig(localConfig);

      expect(registry.active, isA<LocalEmbeddingProvider>());
      expect(registry.active!.providerKey, 'local:embeddinggemma-300m:768');
      expect(registry.active!.supportsImages, isFalse);

      // Persisted config (with both URLs) survives a fresh registry load.
      final reloaded = EmbeddingProviderRegistry();
      await reloaded.initialize();
      expect(reloaded.active, isA<LocalEmbeddingProvider>());
      expect(reloaded.activeConfig?.modelUrl, modelUrl);
      expect(reloaded.activeConfig?.tokenizerUrl, tokenizerUrl);
    });

    test('testConnection on a not-installed local model reports '
        'isNotInstalled (distinct from auth/transient)', () async {
      final registry = EmbeddingProviderRegistry(
        localInstalledCheck: (_) async => false,
      );

      final result = await registry.testConnection(localConfig);

      expect(result.ok, isFalse);
      expect(result.isNotInstalled, isTrue);
      expect(result.isAuthError, isFalse);
      expect(result.isTransient, isFalse);
      expect(result.errorMessage, isNotNull);
    });

    test('testConnection probes offline through an installed local model '
        'and verifies dimensions', () async {
      final registry = EmbeddingProviderRegistry(
        localInstalledCheck: (_) async => true,
        localEmbedFn: (texts, taskType) async {
          expect(texts, [EmbeddingProviderRegistry.probeText]);
          expect(taskType, TaskType.retrievalQuery);
          return [List<double>.filled(768, 0.1)];
        },
      );

      final result = await registry.testConnection(localConfig);

      expect(result.ok, isTrue);
      expect(result.detectedDimensions, 768);
      expect(result.dimensionsMatched, isTrue);
      expect(result.isNotInstalled, isFalse);
    });

    test(
      'testConnection on the ACTIVE local config never disposes the '
      'probe provider (flutter_gemma model is a plugin-level singleton)',
      () async {
        final registry = SpyRegistry(
          installedCheck: (_) async => true,
          embedFn: (texts, taskType) async => [List<double>.filled(768, 0.1)],
        );
        await registry.setActiveConfig(localConfig);

        final result = await registry.testConnection(localConfig);

        expect(result.ok, isTrue);
        // Active provider + probe provider share ONE underlying native model:
        // disposing either would close it under the active provider. Nothing
        // may be disposed here.
        expect(registry.localProviders, hasLength(2));
        for (final provider in registry.localProviders) {
          expect(provider.disposeCalls, 0);
        }
        // The active provider still embeds fine after the probe.
        expect(
          await registry.active!.embedQuery('still works'),
          hasLength(768),
        );
      },
    );

    test('testConnection on a DIFFERENT local config still disposes its '
        'throwaway probe provider', () async {
      final registry = SpyRegistry(
        installedCheck: (_) async => true,
        embedFn: (texts, taskType) async => [List<double>.filled(768, 0.1)],
      );
      await registry.setActiveConfig(localConfig);

      final other = localConfig.copyWith(modelName: 'other-embedder');
      final result = await registry.testConnection(other);

      expect(result.ok, isTrue);
      final probe = registry.localProviders.last;
      expect(probe.config.modelName, 'other-embedder');
      expect(probe.disposeCalls, 1);
      // The ACTIVE provider is untouched.
      expect(registry.localProviders.first.disposeCalls, 0);
    });
  });
}
