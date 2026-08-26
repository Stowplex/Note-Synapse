import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../logger_service.dart';
import 'embedding_provider.dart';
import 'gemini_embedding_provider.dart';
import 'local_embedding_provider.dart';
import 'openai_embedding_provider.dart';

/// Result of probing an embedding config via [EmbeddingProviderRegistry
/// .testConnection]. Used by the settings UI to gate enabling a provider:
/// a wrong dims value must never produce a broken index discovered only via
/// background errors.
class EmbeddingProbeResult {
  final bool ok;

  /// Vector length actually returned by the endpoint (when the probe reached
  /// it and parsed a vector).
  final int? detectedDimensions;

  /// True when [detectedDimensions] equals the configured dimensions.
  final bool dimensionsMatched;

  /// On a dims mismatch, the same config with dimensions corrected to the
  /// detected value; equals the input config when they matched.
  final EmbeddingProviderConfig? correctedConfig;

  final String? errorMessage;
  final bool isAuthError;
  final bool isTransient;

  /// Local providers only: the on-device model files are not installed.
  /// Distinct from auth/transient so the settings UI can offer "Download"
  /// instead of "Fix key"/"Retry".
  final bool isNotInstalled;

  const EmbeddingProbeResult({
    required this.ok,
    this.detectedDimensions,
    this.dimensionsMatched = false,
    this.correctedConfig,
    this.errorMessage,
    this.isAuthError = false,
    this.isTransient = false,
    this.isNotInstalled = false,
  });
}

/// Snapshot of the provider-switch state machine (plan §2.3), for the
/// settings subtitle ("Switching to B — served by A until re-indexing
/// completes") and for orchestration decisions.
class EmbeddingTransitionState {
  const EmbeddingTransitionState({
    this.servingKey,
    this.servingDisplayName,
    this.activeKey,
    this.activeDisplayName,
    this.revokedKey,
  });

  /// providerKey whose stored vectors currently answer semantic queries
  /// (null → lexical-only).
  final String? servingKey;
  final String? servingDisplayName;

  /// providerKey of the configured (target) provider — the one backfilling.
  final String? activeKey;
  final String? activeDisplayName;

  /// providerKey the user explicitly stopped serving ("Stop using A now").
  /// It stays unserved — sweeps and restarts included — until the user
  /// re-enables that provider; null when nothing is revoked.
  final String? revokedKey;

  /// True while the configured provider differs from the serving one: its
  /// backfill has not completed yet (or promotion has not happened).
  bool get inTransition => activeKey != null && activeKey != servingKey;

  /// True when the ACTIVE provider is the revoked one: semantic search stays
  /// off (not "backfilling") until the user re-enables it.
  bool get activeRevoked => activeKey != null && activeKey == revokedKey;
}

/// Resolves the configured embedding provider from persisted settings and
/// builds provider instances.
///
/// Persistence mirrors [ModelStorageService]: the config is stored as JSON in
/// SharedPreferences, while the API key lives in [FlutterSecureStorage] under
/// `'${config.storageId}_api_key'` (same secure-storage options as the chat
/// model keys). Both preset-backed configs and fully custom
/// OpenAI-compatible configs (free-form endpoint + model + dims + optional
/// key) are supported — a custom config is just a config with
/// `isCustom: true` and no matching preset.
///
/// ## Serving key vs active key (provider-switch lifecycle, plan §2.3)
///
/// Semantic queries must be embedded by the SAME provider that produced the
/// stored vectors, so the registry tracks TWO providers:
/// - [active]: the configured provider — the backfill target. Set by
///   [setActiveConfig].
/// - [servingProvider]: the provider whose vectors answer queries right now.
///   On a switch A → B (A still usable) the serving provider STAYS A until
///   B's embed backfill completes; the indexer then calls
///   [promoteActiveToServing] to switch atomically (and GCs A's rows).
///   Turning the provider off ([clearActiveConfig]) or revoking it
///   ([revokeServing]) clears the serving key immediately → lexical-only.
///
/// Promotion is keyed: [promoteActiveToServing] takes the providerKey whose
/// pass finished and no-ops unless it is STILL the active one. A pass that
/// outlives two switches (A → B → C) must never promote C on B's completion
/// — C has no vectors yet, and the caller's GC would delete the rows that
/// are still serving.
///
/// A revoked key is remembered (persisted): it stays unserved across sweeps
/// and restarts until the user re-enables that provider via
/// [setActiveConfig] (or resets the state machine with [clearActiveConfig]).
///
/// All three states are persisted, so an app killed mid-transition restarts
/// with A still serving and B still the backfill target.
class EmbeddingProviderRegistry {
  static const String activeConfigPrefsKey = 'embedding_provider_config';

  /// Persisted serving config (see the class comment). Stored separately
  /// from [activeConfigPrefsKey] so a mid-transition restart resumes with
  /// the old provider still serving.
  static const String servingConfigPrefsKey = 'embedding_serving_config';

  /// Persisted providerKey of an explicitly revoked serving provider (see
  /// [revokeServing]). Durable on purpose: the completeness sweep would
  /// otherwise re-promote it on the next run or app start.
  static const String revokedServingPrefsKey = 'embedding_revoked_serving_key';

  /// Probe text used by [testConnection].
  static const String probeText = 'Note Synapse embedding connection probe';

  final FlutterSecureStorage _storage;
  final EmbeddingHttpPost? _httpPost;
  final LocalEmbedderInstalledCheck? _localInstalledCheck;
  final LocalEmbedFn? _localEmbedFn;
  final EmbeddingProvider? Function(EmbeddingProviderConfig config)?
  _providerBuilder;

  EmbeddingProviderConfig? _activeConfig;
  EmbeddingProvider? _active;
  EmbeddingProviderConfig? _servingConfig;
  EmbeddingProvider? _servingProvider;

  /// providerKey of the last explicitly revoked serving provider (mirrors
  /// [revokedServingPrefsKey]).
  String? _revokedServingKey;

  /// Memoized first [initialize] — callers that merely need the persisted
  /// state loaded (indexer, search) await this instead of re-reading prefs.
  Future<void>? _initialized;

  /// In-flight guard serializing the mutating operations ([initialize],
  /// [setActiveConfig], [clearActiveConfig]). Each chains onto the previous
  /// pending future, so a slow [initialize] (e.g. awaiting secure storage)
  /// can never complete late and clobber a fresher [setActiveConfig].
  Future<void> _pending = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    // Keep the chain alive even when an action fails; errors still surface
    // to that action's own caller via [result].
    _pending = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Swap the active config/provider, releasing the previous provider's
  /// native resources when it held any (only local providers do — the HTTP
  /// providers are stateless). Never disposes a provider that is still the
  /// SERVING provider: during an A → B transition A keeps embedding queries.
  void _replaceActive(
    EmbeddingProviderConfig? config,
    EmbeddingProvider? provider,
  ) {
    final previous = _active;
    _activeConfig = config;
    _active = provider;
    if (previous is LocalEmbeddingProvider &&
        !identical(previous, provider) &&
        !identical(previous, _servingProvider)) {
      unawaited(previous.dispose());
    }
  }

  /// Swap the serving config/provider with the same disposal rules
  /// (mirrored: never dispose a provider that is still the ACTIVE one).
  void _replaceServing(
    EmbeddingProviderConfig? config,
    EmbeddingProvider? provider,
  ) {
    final previous = _servingProvider;
    _servingConfig = config;
    _servingProvider = provider;
    if (previous is LocalEmbeddingProvider &&
        !identical(previous, provider) &&
        !identical(previous, _active)) {
      unawaited(previous.dispose());
    }
  }

  /// Creates a registry. [storage], [httpPost], and the local-provider seams
  /// ([localInstalledCheck], [localEmbedFn]) are injectable for tests
  /// (mirrors ModelStorageService's optional-storage constructor;
  /// flutter_gemma's platform channel is unavailable in unit tests).
  ///
  /// [providerBuilder] (tests only) intercepts [buildProvider]: returning a
  /// non-null provider replaces the built-in type switch, so tests can hand
  /// the pipeline a scripted fake with arbitrary maxBatchSize/failures.
  EmbeddingProviderRegistry({
    FlutterSecureStorage? storage,
    EmbeddingHttpPost? httpPost,
    LocalEmbedderInstalledCheck? localInstalledCheck,
    LocalEmbedFn? localEmbedFn,
    @visibleForTesting
    EmbeddingProvider? Function(EmbeddingProviderConfig config)?
    providerBuilder,
  }) : _providerBuilder = providerBuilder,
       _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(
               encryptedSharedPreferences: true,
               sharedPreferencesName: 'note_synapse_secure',
               preferencesKeyPrefix: 'note_synapse_',
             ),
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock_this_device,
             ),
           ),
       _httpPost = httpPost,
       _localInstalledCheck = localInstalledCheck,
       _localEmbedFn = localEmbedFn;

  /// The currently configured provider, or null when semantic search is off
  /// ("None (lexical only)"). Populated by [initialize]/[setActiveConfig].
  /// This is the BACKFILL TARGET; queries use [servingProvider].
  EmbeddingProvider? get active => _active;

  EmbeddingProviderConfig? get activeConfig => _activeConfig;

  /// The provider whose stored vectors answer semantic queries right now
  /// (query embeddings must come from it too). Null → lexical-only. Lags
  /// [active] during a provider switch; see the class comment.
  EmbeddingProvider? get servingProvider => _servingProvider;

  EmbeddingProviderConfig? get servingConfig => _servingConfig;

  String? get servingProviderKey => _servingConfig?.providerKey;

  /// providerKey the user explicitly stopped serving, or null. Auto-promotion
  /// of this key is suppressed until it is re-enabled — see [revokeServing].
  String? get revokedServingKey => _revokedServingKey;

  /// Whether [providerKey] is currently revoked from serving (the indexer's
  /// completeness check consults this instead of re-promoting it).
  bool isServingRevoked(String providerKey) =>
      _revokedServingKey == providerKey;

  /// Snapshot for the settings subtitle and orchestration checks.
  EmbeddingTransitionState get transitionState => EmbeddingTransitionState(
    servingKey: _servingConfig?.providerKey,
    servingDisplayName: _servingConfig?.displayName,
    activeKey: _activeConfig?.providerKey,
    activeDisplayName: _activeConfig?.displayName,
    revokedKey: _revokedServingKey,
  );

  /// Load the persisted config (and its API key) and build the active
  /// provider. Safe to call again to reload after external settings changes.
  Future<void> initialize() {
    final run = _serialized(_initialize);
    _initialized ??= run;
    return run;
  }

  /// Await the first [initialize] (running it if nobody has yet). Pipeline
  /// and query paths call this before consulting [active]/[servingProvider].
  Future<void> ensureInitialized() => _initialized ?? initialize();

  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _revokedServingKey = prefs.getString(revokedServingPrefsKey);
      final config = await _loadConfigWithKey(prefs, activeConfigPrefsKey);
      if (config == null) {
        _replaceActive(null, null);
      } else {
        _replaceActive(config, buildProvider(config));
      }

      final servingConfig = await _loadConfigWithKey(
        prefs,
        servingConfigPrefsKey,
      );
      if (servingConfig == null) {
        _replaceServing(null, null);
      } else if (servingConfig.providerKey == _activeConfig?.providerKey) {
        // Aligned (no transition in flight): share the active instance so
        // local providers hold one native handle, not two.
        _replaceServing(_activeConfig, _active);
      } else {
        _replaceServing(servingConfig, buildProvider(servingConfig));
      }
    } catch (e) {
      LoggerService.error(
        'EmbeddingProviderRegistry: error loading active config: $e',
      );
      _replaceActive(null, null);
      _replaceServing(null, null);
      _revokedServingKey = null;
    }
  }

  /// Read + decode a persisted config and resolve its API key from secure
  /// storage. Null when absent or unparseable.
  Future<EmbeddingProviderConfig?> _loadConfigWithKey(
    SharedPreferences prefs,
    String prefsKey,
  ) async {
    final configJson = prefs.getString(prefsKey);
    if (configJson == null) return null;
    try {
      var config = EmbeddingProviderConfig.fromJson(
        jsonDecode(configJson) as Map<String, dynamic>,
      );
      final apiKey = await getApiKey(config);
      if (apiKey != null && apiKey.isNotEmpty) {
        config = config.copyWith(apiKey: apiKey);
      }
      return config;
    } catch (e) {
      LoggerService.error(
        'EmbeddingProviderRegistry: could not parse config at $prefsKey: $e',
      );
      return null;
    }
  }

  /// Persist [config] as the active embedding provider and rebuild [active].
  /// When [apiKey] is provided it is saved to secure storage; otherwise any
  /// previously stored key for this config is reused.
  ///
  /// Serving-key rules (plan §2.3):
  /// - Same providerKey as the current serving one (config edit / key fix /
  ///   switch-back mid-transition): serving is refreshed to the new instance
  ///   — no transition.
  /// - Different providerKey: the serving provider is left UNTOUCHED (old
  ///   provider keeps answering queries) until the indexer completes the new
  ///   key's backfill and calls [promoteActiveToServing]. With no serving
  ///   provider, search stays lexical-only until then.
  ///
  /// Selecting a REVOKED providerKey here is the explicit "use it again"
  /// gesture: its revocation is lifted, so the next completed pass (or the
  /// completeness sweep, when its vectors are still current) promotes it.
  Future<void> setActiveConfig(
    EmbeddingProviderConfig config, {
    String? apiKey,
  }) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(activeConfigPrefsKey, jsonEncode(config.toJson()));
      if (_revokedServingKey == config.providerKey) {
        await prefs.remove(revokedServingPrefsKey);
        _revokedServingKey = null;
      }
      if (apiKey != null) {
        await _storage.write(key: _apiKeyStorageKey(config), value: apiKey);
      }
      final resolvedKey = apiKey ?? await getApiKey(config);
      final resolvedConfig = config.copyWith(apiKey: resolvedKey);
      final provider = buildProvider(resolvedConfig);
      _replaceActive(resolvedConfig, provider);
      if (_servingConfig?.providerKey == resolvedConfig.providerKey) {
        // Aligned key: keep serving in lockstep (fresh key/instance) and
        // persist so a restart stays aligned.
        await prefs.setString(
          servingConfigPrefsKey,
          jsonEncode(resolvedConfig.toJson()),
        );
        _replaceServing(resolvedConfig, provider);
      }
    });
  }

  /// Atomically make the ACTIVE provider the SERVING one. Called by the
  /// indexer once [expectedKey]'s embed backfill is complete (its global
  /// state row turned done).
  ///
  /// [expectedKey] is the key whose pass finished. The promotion is a NO-OP
  /// unless it is still the active one — a pass takes minutes on a real
  /// corpus, and the user may have switched again while it ran; promoting
  /// whatever happens to be active NOW would serve a provider with no
  /// vectors (and the caller's GC would then delete the rows still in use).
  /// It is equally a no-op for a revoked key (see [revokeServing]).
  ///
  /// Returns whether serving changed, plus the previous serving key (for the
  /// caller's lazy GC of its stored vectors). `promoted: false` means
  /// NOTHING changed — the caller must not GC.
  Future<({bool promoted, String? previousKey})> promoteActiveToServing(
    String expectedKey,
  ) {
    return _serialized(() async {
      const unchanged = (promoted: false, previousKey: null);
      final config = _activeConfig;
      if (config == null) return unchanged;
      if (config.providerKey != expectedKey) return unchanged;
      if (_revokedServingKey == expectedKey) return unchanged;
      final previousKey = _servingConfig?.providerKey;
      if (previousKey == config.providerKey) return unchanged;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(servingConfigPrefsKey, jsonEncode(config.toJson()));
      _replaceServing(config, _active);
      return (promoted: true, previousKey: previousKey);
    });
  }

  /// Immediately stop serving semantic queries (lexical-only until the
  /// active provider's backfill completes and promotes). Used for "Stop
  /// using A now" during a transition, or when A's key is revoked. The
  /// active (target) config is untouched.
  ///
  /// The revoked key is REMEMBERED (persisted): with A still the active
  /// provider its stored vectors are complete, so the indexer's completeness
  /// sweep would otherwise silently re-promote A on the next run or app
  /// start. Re-enabling A in settings ([setActiveConfig]) lifts it.
  Future<void> revokeServing() {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      // Only what was actually serving is revoked; with nothing serving
      // there is no decision to remember (the active key promotes normally
      // once its backfill completes).
      final revoked = _servingConfig?.providerKey;
      await prefs.remove(servingConfigPrefsKey);
      if (revoked != null) {
        await prefs.setString(revokedServingPrefsKey, revoked);
        _revokedServingKey = revoked;
      }
      _replaceServing(null, null);
    });
  }

  /// Switch to "None (lexical only)": semantic off instantly (the serving
  /// key and any revocation are cleared too — picking a provider again is a
  /// fresh start for the state machine). Stored vectors are NOT touched here
  /// — plan §2.3 keeps them so re-enabling the same providerKey needs no
  /// re-embed; NoteIndexService.deleteStoredEmbeddings covers explicit
  /// deletion.
  /// Stored API keys are kept by default so re-enabling the same provider
  /// needs no re-entry; pass [deleteApiKey] to remove the key as well.
  Future<void> clearActiveConfig({bool deleteApiKey = false}) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      if (deleteApiKey) {
        // On an uninitialized registry _activeConfig is still null even
        // though a config (and key) may be persisted — load it so the key
        // actually gets deleted instead of being silently left behind.
        var config = _activeConfig;
        if (config == null) {
          final configJson = prefs.getString(activeConfigPrefsKey);
          if (configJson != null) {
            try {
              config = EmbeddingProviderConfig.fromJson(
                jsonDecode(configJson) as Map<String, dynamic>,
              );
            } catch (e) {
              LoggerService.error(
                'EmbeddingProviderRegistry: could not parse persisted '
                'config while deleting its key: $e',
              );
            }
          }
        }
        if (config != null) {
          await _storage.delete(key: _apiKeyStorageKey(config));
        }
      }
      await prefs.remove(activeConfigPrefsKey);
      await prefs.remove(servingConfigPrefsKey);
      await prefs.remove(revokedServingPrefsKey);
      _replaceActive(null, null);
      _replaceServing(null, null);
      _revokedServingKey = null;
    });
  }

  /// Read the stored API key for [config] from secure storage.
  Future<String?> getApiKey(EmbeddingProviderConfig config) async {
    try {
      return await _storage.read(key: _apiKeyStorageKey(config));
    } catch (e) {
      LoggerService.error('EmbeddingProviderRegistry: error reading key: $e');
      return null;
    }
  }

  /// Write [apiKey] into the SAME secure-storage slot [getApiKey] reads
  /// (`'${config.storageId}_api_key'`, endpoint-scoped for OpenAI-compatible
  /// configs), WITHOUT activating [config].
  ///
  /// [setActiveConfig] already saves a key it is handed, so this exists for
  /// the one flow that needs the credential BEFORE the provider can be
  /// enabled: a gated on-device model download (the HuggingFace token is
  /// required to fetch the weights, and the provider must not go active until
  /// they are on the device). Callers must use this rather than a
  /// hand-rolled FlutterSecureStorage — the storage instance and its
  /// Android/iOS options live here, and a registry built with INJECTED
  /// storage (tests) would otherwise read a different store than the writer
  /// wrote to.
  ///
  /// Storage failures are logged and swallowed: the caller's in-flight use of
  /// the key still works, it just is not remembered.
  Future<void> saveApiKey(EmbeddingProviderConfig config, String apiKey) async {
    try {
      await _storage.write(key: _apiKeyStorageKey(config), value: apiKey);
    } catch (e) {
      LoggerService.error('EmbeddingProviderRegistry: error saving key: $e');
    }
  }

  String _apiKeyStorageKey(EmbeddingProviderConfig config) =>
      '${config.storageId}_api_key';

  /// Build a provider instance for [config] (its `apiKey` field must already
  /// be resolved). Returns null for unknown types.
  EmbeddingProvider? buildProvider(EmbeddingProviderConfig config) {
    final overridden = _providerBuilder?.call(config);
    if (overridden != null) return overridden;
    switch (config.type) {
      case 'gemini':
        return GeminiEmbeddingProvider(config, httpPost: _httpPost);
      case 'openai':
        return OpenAIEmbeddingProvider(config, httpPost: _httpPost);
      case 'local':
        return LocalEmbeddingProvider(
          config,
          installedCheck: _localInstalledCheck,
          embedFn: _localEmbedFn,
        );
      default:
        LoggerService.error(
          'EmbeddingProviderRegistry: unknown provider type "${config.type}"',
        );
        return null;
    }
  }

  /// Probe [config] by embedding a short string, verifying/auto-detecting
  /// `dimensions` from the response vector length. [apiKey] overrides the
  /// stored key (settings UI passes the freshly typed key before saving).
  ///
  /// Local configs probe fully offline through the on-device model; when its
  /// files are not installed the result carries `isNotInstalled: true` so
  /// the settings UI offers "Download" rather than auth/retry actions.
  Future<EmbeddingProbeResult> testConnection(
    EmbeddingProviderConfig config, {
    String? apiKey,
  }) async {
    final resolvedKey = apiKey ?? await getApiKey(config);
    final probeConfig = resolvedKey != null && resolvedKey.isNotEmpty
        ? config.copyWith(apiKey: resolvedKey)
        : config;

    final provider = buildProvider(probeConfig);
    if (provider == null) {
      return EmbeddingProbeResult(
        ok: false,
        errorMessage: 'Unknown provider type "${config.type}"',
      );
    }

    try {
      final vector = await provider.embedQuery(probeText);
      if (vector.isEmpty) {
        return const EmbeddingProbeResult(
          ok: false,
          errorMessage: 'Provider returned an empty embedding vector',
        );
      }
      final detected = vector.length;
      final matched = detected == config.dimensions;
      return EmbeddingProbeResult(
        ok: true,
        detectedDimensions: detected,
        dimensionsMatched: matched,
        correctedConfig: matched
            ? config
            : config.copyWith(dimensions: detected),
      );
    } on EmbeddingProviderException catch (e) {
      final detected = e.detectedDimensions;
      if (detected != null) {
        // Providers throw on a dims mismatch to protect indexing paths that
        // skipped testConnection; for the probe itself a mismatch IS the
        // successful auto-detection — map it back to a corrected config.
        return EmbeddingProbeResult(
          ok: true,
          detectedDimensions: detected,
          dimensionsMatched: false,
          correctedConfig: config.copyWith(dimensions: detected),
        );
      }
      return EmbeddingProbeResult(
        ok: false,
        errorMessage: e.message,
        isAuthError: e.isAuthError,
        isTransient: e.isTransient,
        isNotInstalled: e.isNotInstalled,
      );
    } catch (e) {
      return EmbeddingProbeResult(ok: false, errorMessage: e.toString());
    } finally {
      if (provider is LocalEmbeddingProvider &&
          !identical(provider, _active) &&
          config.providerKey != _activeConfig?.providerKey &&
          !identical(provider, _servingProvider) &&
          config.providerKey != _servingConfig?.providerKey) {
        // The throwaway probe provider may have lazily opened the on-device
        // model; release it. NEVER when the probe targets the ACTIVE local
        // config: flutter_gemma's embedding model is a PLUGIN-LEVEL
        // singleton keyed by spec name, so the probe provider and the
        // active provider share ONE native instance — disposing the probe
        // would close the model out from under the active provider and
        // break every later embed until it self-heals via re-init.
        unawaited(provider.dispose());
      }
    }
  }
}
