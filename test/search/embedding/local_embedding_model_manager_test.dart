import 'dart:async';

import 'package:flutter_gemma/core/domain/download_error.dart';
import 'package:flutter_gemma/core/domain/download_exception.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/local_embedding_model_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const modelFilename = 'embeddinggemma-300M_seq512_mixed-precision.tflite';
  const tokenizerFilename = 'sentencepiece.model';

  const localConfig = EmbeddingProviderConfig(
    type: 'local',
    modelName: 'embeddinggemma-300m',
    displayName: 'EmbeddingGemma (on-device)',
    dimensions: 768,
    modelUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/'
        'resolve/main/$modelFilename',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/'
        'resolve/main/$tokenizerFilename',
  );

  /// Runs [LocalEmbeddingModelManager.install] to completion, returning all
  /// progress events plus the terminal outcome (null = success).
  Future<
    ({
      List<LocalEmbeddingDownloadProgress> events,
      LocalEmbeddingInstallError? outcome,
    })
  >
  runInstall(
    LocalEmbeddingModelManager manager,
    EmbeddingProviderConfig config, {
    String? authToken,
  }) async {
    final outcome = Completer<LocalEmbeddingInstallError?>();
    final stream = manager.install(
      config,
      authToken: authToken,
      onComplete: () => outcome.complete(null),
      onError: outcome.complete,
    );
    // toList() completes when the stream closes, which happens strictly
    // after the terminal callback fired.
    final events = await stream.toList();
    return (events: events, outcome: await outcome.future);
  }

  group('install error mapping (typed DownloadException)', () {
    Future<LocalEmbeddingInstallError?> outcomeFor(Object failure) async {
      final manager = LocalEmbeddingModelManager(
        fileInstalledCheck: (_) async => false,
        installOp: (config, token, onModel, onTokenizer) async {
          throw failure;
        },
      );
      return (await runInstall(manager, localConfig)).outcome;
    }

    test('401 unauthorized (gated HF repo) maps to isAuthError', () async {
      final error = await outcomeFor(
        const DownloadException(DownloadError.unauthorized()),
      );
      expect(error, isNotNull);
      expect(error!.isAuthError, isTrue);
      expect(error.isTransient, isFalse);
      expect(error.message, isNotEmpty);
    });

    test('403 forbidden (token lacks access) maps to isAuthError', () async {
      final error = await outcomeFor(
        const DownloadException(DownloadError.forbidden()),
      );
      expect(error!.isAuthError, isTrue);
      expect(error.isTransient, isFalse);
    });

    test('network failure maps to isTransient', () async {
      final error = await outcomeFor(
        const DownloadException(DownloadError.network('connection reset')),
      );
      expect(error!.isTransient, isTrue);
      expect(error.isAuthError, isFalse);
    });

    test('5xx maps to isTransient', () async {
      final error = await outcomeFor(
        const DownloadException(DownloadError.serverError(503)),
      );
      expect(error!.isTransient, isTrue);
      expect(error.isAuthError, isFalse);
    });

    test('429 rate limit maps to isTransient', () async {
      final error = await outcomeFor(
        const DownloadException(DownloadError.rateLimited()),
      );
      expect(error!.isTransient, isTrue);
    });

    test('404 not-found is permanent: neither auth nor transient', () async {
      final error = await outcomeFor(
        const DownloadException(DownloadError.notFound()),
      );
      expect(error!.isAuthError, isFalse);
      expect(error.isTransient, isFalse);
    });

    test(
      'non-DownloadException failures keep their message with no flags',
      () async {
        final error = await outcomeFor(StateError('builder exploded'));
        expect(error!.isAuthError, isFalse);
        expect(error.isTransient, isFalse);
        expect(error.message, contains('builder exploded'));
      },
    );

    test(
      'config without download URLs errors out without installing',
      () async {
        var installCalls = 0;
        final manager = LocalEmbeddingModelManager(
          fileInstalledCheck: (_) async => false,
          installOp: (config, token, onModel, onTokenizer) async {
            installCalls++;
          },
        );
        const urlLess = EmbeddingProviderConfig(
          type: 'local',
          modelName: 'no-urls',
          displayName: 'No URLs',
          dimensions: 768,
        );

        final result = await runInstall(manager, urlLess);

        expect(result.outcome, isNotNull);
        expect(result.outcome!.isAuthError, isFalse);
        expect(result.outcome!.isTransient, isFalse);
        expect(installCalls, 0);
      },
    );
  });

  group('install progress', () {
    test('pre-credits an already-installed model file so the combined bar '
        'starts at its weight instead of 3%', () async {
      final manager = LocalEmbeddingModelManager(
        // Model file already present; only the tokenizer downloads.
        fileInstalledCheck: (filename) async => filename == modelFilename,
        installOp: (config, token, onModel, onTokenizer) async {
          onTokenizer(50);
          onTokenizer(100);
        },
      );

      final result = await runInstall(manager, localConfig);

      expect(result.outcome, isNull);
      expect(result.events, isNotEmpty);
      final first = result.events.first;
      expect(first.modelProgressPercent, 100);
      expect(first.tokenizerProgressPercent, 0);
      expect(first.progressPercent, 97);
      expect(result.events.last.progressPercent, 100);
    });

    test('pre-credits an already-installed tokenizer so the bar can reach '
        '100%', () async {
      final manager = LocalEmbeddingModelManager(
        fileInstalledCheck: (filename) async => filename == tokenizerFilename,
        installOp: (config, token, onModel, onTokenizer) async {
          onModel(100);
        },
      );

      final result = await runInstall(manager, localConfig);

      expect(result.outcome, isNull);
      expect(result.events.first.tokenizerProgressPercent, 100);
      expect(result.events.first.progressPercent, 3);
      expect(result.events.last.progressPercent, 100);
    });

    test('fresh install reports both files without pre-credit', () async {
      final manager = LocalEmbeddingModelManager(
        fileInstalledCheck: (_) async => false,
        installOp: (config, token, onModel, onTokenizer) async {
          onModel(100);
          onTokenizer(100);
        },
      );

      final result = await runInstall(manager, localConfig);

      expect(result.outcome, isNull);
      expect(result.events.first.progressPercent, 97);
      expect(result.events.last.progressPercent, 100);
    });
  });

  group('concurrent install dedup', () {
    test('a second install for the same config joins the in-flight download '
        'instead of starting a duplicate', () async {
      var installCalls = 0;
      final release = Completer<void>();
      final manager = LocalEmbeddingModelManager(
        fileInstalledCheck: (_) async => false,
        installOp: (config, token, onModel, onTokenizer) async {
          installCalls++;
          await release.future;
          onModel(100);
          onTokenizer(100);
        },
      );

      final firstOutcome = Completer<LocalEmbeddingInstallError?>();
      final firstEvents = <LocalEmbeddingDownloadProgress>[];
      manager
          .install(
            localConfig,
            onComplete: () => firstOutcome.complete(null),
            onError: firstOutcome.complete,
          )
          .listen(firstEvents.add);

      final secondOutcome = Completer<LocalEmbeddingInstallError?>();
      final secondEvents = <LocalEmbeddingDownloadProgress>[];
      manager
          .install(
            localConfig,
            onComplete: () => secondOutcome.complete(null),
            onError: secondOutcome.complete,
          )
          .listen(secondEvents.add);

      release.complete();

      expect(await firstOutcome.future, isNull);
      expect(await secondOutcome.future, isNull);
      // ONE download ran; both callers observed its progress and outcome.
      expect(installCalls, 1);
      expect(firstEvents.last.progressPercent, 100);
      expect(secondEvents.last.progressPercent, 100);
    });

    test('joined installs share the SAME failure', () async {
      var installCalls = 0;
      final release = Completer<void>();
      final manager = LocalEmbeddingModelManager(
        fileInstalledCheck: (_) async => false,
        installOp: (config, token, onModel, onTokenizer) async {
          installCalls++;
          await release.future;
          throw const DownloadException(DownloadError.unauthorized());
        },
      );

      final outcomes = <Future<LocalEmbeddingInstallError?>>[];
      for (var i = 0; i < 2; i++) {
        final outcome = Completer<LocalEmbeddingInstallError?>();
        manager.install(
          localConfig,
          onComplete: () => outcome.complete(null),
          onError: outcome.complete,
        );
        outcomes.add(outcome.future);
      }
      release.complete();

      for (final outcome in await Future.wait(outcomes)) {
        expect(outcome, isNotNull);
        expect(outcome!.isAuthError, isTrue);
      }
      expect(installCalls, 1);
    });

    test(
      'after completion a new install starts fresh (memo is cleared)',
      () async {
        var installCalls = 0;
        final manager = LocalEmbeddingModelManager(
          fileInstalledCheck: (_) async => false,
          installOp: (config, token, onModel, onTokenizer) async {
            installCalls++;
            onModel(100);
            onTokenizer(100);
          },
        );

        expect((await runInstall(manager, localConfig)).outcome, isNull);
        expect((await runInstall(manager, localConfig)).outcome, isNull);
        expect(installCalls, 2);
      },
    );
  });

  group('uninstall', () {
    test('closes the live active embedder BEFORE deleting its files', () async {
      final order = <String>[];
      final manager = LocalEmbeddingModelManager(
        closeActiveEmbedderOp: (config) async => order.add('close'),
        fileInstalledCheck: (filename) async {
          order.add('check:$filename');
          return true;
        },
        fileUninstallOp: (filename) async => order.add('delete:$filename'),
      );

      await manager.uninstall(localConfig);

      expect(order.first, 'close');
      expect(order, contains('delete:$modelFilename'));
      expect(order, contains('delete:$tokenizerFilename'));
      expect(
        order.indexOf('close'),
        lessThan(order.indexOf('delete:$modelFilename')),
      );
    });

    test('skips deletion of files that are not installed', () async {
      final deleted = <String>[];
      final manager = LocalEmbeddingModelManager(
        closeActiveEmbedderOp: (_) async {},
        fileInstalledCheck: (filename) async => filename == modelFilename,
        fileUninstallOp: (filename) async => deleted.add(filename),
      );

      await manager.uninstall(localConfig);

      expect(deleted, [modelFilename]);
    });
  });

  group('isInstalled', () {
    test('true only when BOTH files are installed', () async {
      Future<bool> installedWith(Set<String> present) {
        final manager = LocalEmbeddingModelManager(
          fileInstalledCheck: (filename) async => present.contains(filename),
        );
        return manager.isInstalled(localConfig);
      }

      expect(await installedWith({modelFilename, tokenizerFilename}), isTrue);
      expect(await installedWith({modelFilename}), isFalse);
      expect(await installedWith({tokenizerFilename}), isFalse);
      expect(await installedWith({}), isFalse);
    });

    test('false for configs without download URLs', () async {
      final manager = LocalEmbeddingModelManager(
        fileInstalledCheck: (_) async => true,
      );
      const urlLess = EmbeddingProviderConfig(
        type: 'local',
        modelName: 'no-urls',
        displayName: 'No URLs',
        dimensions: 768,
      );
      expect(await manager.isInstalled(urlLess), isFalse);
    });
  });
}
