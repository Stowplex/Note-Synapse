import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import 'data_change_notifier.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'note_modification_service.dart';
import 'block_note_scope_service.dart';
import 'content_ingestion_service.dart';
import 'conversation_service.dart';
import 'user_app_service.dart';
import 'model_storage_service.dart';
import 'model_preference_service.dart';
import 'model_selector.dart';
import 'local_model_service.dart';
import 'sql_query_service.dart';
import 'context_manager_service.dart';
import 'ai_service.dart';
import 'agent_service.dart';
import 'mcp_service.dart';
import 'tag_image_service.dart';
import 'note_marker_service.dart';
import 'note_annotation_service.dart';
import 'skill_service.dart';
import 'tag_workflow_service.dart';
import 'fork_service.dart';
import 'marker_chat_send_service.dart';
import 'prompts/prompt_template_service.dart';
import 'search_settings_service.dart';
import 'search/embedding/embedding_provider_registry.dart';
import 'search/note_index_service.dart';
import 'search/search_service.dart';
import 'search/vector_search.dart';
import 'tts_service.dart';
import 'web_session_service.dart';
import 'app_domain_grant_service.dart';
import 'crypto_service.dart';
import 'plugin_task_service.dart';
import 'sync/cloud_sync_service.dart';
import 'sync/google_drive_auth_service.dart';
import 'world_clip/frame_correction.dart';
import 'world_clip/video_source.dart';
import 'world_clip/screen_capture_service.dart';

/// Global GetIt instance for service location.
final GetIt getIt = GetIt.instance;

/// Initialize all services. Call once in main() before runApp().
///
/// ## Testing
///
/// For unit tests, call [resetForTesting] in setUp(), then register mocks:
///
/// ```dart
/// setUp(() {
///   resetForTesting();
///   getIt.registerSingleton<DatabaseService>(MockDatabaseService());
/// });
/// ```
///
/// ## Dependency Graph
///
/// Services are registered in dependency order. See each wave section
/// for which services depend on which.
void setupServiceLocator() {
  // ============================================================
  // WAVE 1: Foundation - No dependencies
  // ============================================================
  if (!getIt.isRegistered<PromptTemplateService>()) {
    getIt.registerLazySingleton<PromptTemplateService>(
      () => PromptTemplateService(),
    );
  }

  if (!getIt.isRegistered<DatabaseService>()) {
    getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  }

  // Must be registered before AppProvider and the services that publish to
  // it (NoteModificationService, SqlQueryService): data-layer writers
  // publish change events here and AppProvider subscribes to refresh the UI
  // caches.
  if (!getIt.isRegistered<DataChangeNotifier>()) {
    getIt.registerLazySingleton<DataChangeNotifier>(() => DataChangeNotifier());
  }

  if (!getIt.isRegistered<McpService>()) {
    getIt.registerLazySingleton<McpService>(() => McpService());
  }

  if (!getIt.isRegistered<AppDomainGrantService>()) {
    getIt.registerLazySingleton<AppDomainGrantService>(
      () => AppDomainGrantService(),
    );
  }

  // Depends on AppDomainGrantService (registered just above): deleting a
  // session must also revoke any app grants against that domain.
  if (!getIt.isRegistered<WebSessionService>()) {
    getIt.registerLazySingleton<WebSessionService>(
      () => WebSessionService(grantService: getIt<AppDomainGrantService>()),
    );
  }

  if (!getIt.isRegistered<CryptoService>()) {
    getIt.registerLazySingleton<CryptoService>(() => CryptoService());
  }

  if (!getIt.isRegistered<PluginTaskService>()) {
    getIt.registerLazySingleton<PluginTaskService>(() => PluginTaskService());
  }

  // Registered so non-widget services (e.g. PluginTaskService firing a plugin
  // tool from a background timer) can reach the same AppProvider the UI uses.
  // main.dart provides this same instance via ChangeNotifierProvider.value.
  if (!getIt.isRegistered<AppProvider>()) {
    getIt.registerLazySingleton<AppProvider>(() => AppProvider());
  }

  if (!getIt.isRegistered<TtsService>()) {
    getIt.registerLazySingleton<TtsService>(() => TtsService());
  }

  // ============================================================
  // WAVE 2: Simple services - Depend only on DatabaseService
  // ============================================================
  if (!getIt.isRegistered<NoteModificationService>()) {
    getIt.registerLazySingleton<NoteModificationService>(
      () => NoteModificationService(
        getIt<DatabaseService>(),
        changeNotifier: getIt<DataChangeNotifier>(),
      ),
    );
  }

  if (!getIt.isRegistered<BlockNoteScopeService>()) {
    getIt.registerLazySingleton<BlockNoteScopeService>(
      () => BlockNoteScopeService(
        getIt<DatabaseService>(),
        changeNotifier: getIt<DataChangeNotifier>(),
      ),
    );
  }

  if (!getIt.isRegistered<ContentIngestionService>()) {
    getIt.registerLazySingleton<ContentIngestionService>(
      () => ContentIngestionService(getIt<DatabaseService>()),
    );
  }

  if (!getIt.isRegistered<ConversationService>()) {
    getIt.registerLazySingleton<ConversationService>(
      () => ConversationService(getIt<DatabaseService>()),
    );
  }

  if (!getIt.isRegistered<TagImageService>()) {
    getIt.registerLazySingleton<TagImageService>(
      () => TagImageService(getIt<DatabaseService>()),
    );
  }

  if (!getIt.isRegistered<NoteMarkerService>()) {
    getIt.registerLazySingleton<NoteMarkerService>(
      () => NoteMarkerService(getIt<DatabaseService>()),
    );
  }

  if (!getIt.isRegistered<NoteAnnotationService>()) {
    getIt.registerLazySingleton<NoteAnnotationService>(
      () => NoteAnnotationService(getIt<DatabaseService>()),
    );
  }

  if (!getIt.isRegistered<SkillService>()) {
    getIt.registerLazySingleton<SkillService>(
      () => SkillService(getIt<DatabaseService>()),
    );
  }

  if (!getIt.isRegistered<TagWorkflowService>()) {
    getIt.registerLazySingleton<TagWorkflowService>(
      () => TagWorkflowService(getIt<DatabaseService>()),
    );
  }

  // Semantic layer (plan §2.3). The registry resolves the configured
  // embedding provider from persisted settings; initialize() is kicked off
  // here (fire-and-forget) so the serving/active keys are loaded before the
  // first search — every consumer also awaits ensureInitialized() itself,
  // so nothing depends on this completing first.
  if (!getIt.isRegistered<EmbeddingProviderRegistry>()) {
    getIt.registerLazySingleton<EmbeddingProviderRegistry>(
      () => EmbeddingProviderRegistry(),
    );
    unawaited(
      getIt<EmbeddingProviderRegistry>().initialize().catchError((Object e) {
        LoggerService.error(
          '[ServiceLocator] Embedding registry init failed: $e',
          error: e,
        );
      }),
    );
  }

  if (!getIt.isRegistered<VectorSearch>()) {
    getIt.registerLazySingleton<VectorSearch>(
      () => VectorSearch(getIt<DatabaseService>()),
    );
  }

  if (!getIt.isRegistered<NoteIndexService>()) {
    getIt.registerLazySingleton<NoteIndexService>(
      () => NoteIndexService(
        getIt<DatabaseService>(),
        changeNotifier: getIt<DataChangeNotifier>(),
        embeddingRegistry: getIt<EmbeddingProviderRegistry>(),
        vectorSearch: getIt<VectorSearch>(),
        // Wifi-only backfill gate (plan §2.2). The registry lookup MUST stay
        // inside the closure body: registerLazySingleton evaluates its
        // factory's arguments once, at first resolution, so a hoisted
        // getIt<EmbeddingProviderRegistry>().activeConfig would freeze the
        // provider type as it was at startup (typically null → treated as
        // cloud) and permanently wifi-gate a provider configured later — a
        // LOCAL provider uploads nothing and must never be gated. Evaluated
        // per embed batch here, so it also follows a provider switch.
        embedNetworkAllowed: () =>
            SearchSettingsService().embedBackfillNetworkAllowed(
              isCloudProvider:
                  getIt<EmbeddingProviderRegistry>().activeConfig?.type !=
                  'local',
            ),
      ),
    );
    // Resolve eagerly: constructing the indexer is what registers its
    // DatabaseService write-path hooks and DataChangeNotifier subscription —
    // they must be live from startup, not from first UI use.
    getIt<NoteIndexService>();
  }

  if (!getIt.isRegistered<SearchService>()) {
    getIt.registerLazySingleton<SearchService>(
      () => SearchService(
        getIt<DatabaseService>(),
        getIt<NoteIndexService>(),
        embeddingRegistry: getIt<EmbeddingProviderRegistry>(),
        vectorSearch: getIt<VectorSearch>(),
        // Substring-fallback note source (Step 5 inversion): read
        // AppProvider's in-memory note cache instead of a full-table read
        // per keystroke. SearchService never imports AppProvider — the
        // coupling lives only here in the composition root, resolved lazily
        // at call time via getIt (AppProvider is registered above; main.dart
        // provides the same instance to the widget tree). This must NEVER
        // trigger AppProvider.loadData: before the first load completes the
        // cache is unpopulated, so fall back to a direct database read.
        notesProvider: () async {
          final appProvider = getIt<AppProvider>();
          if (appProvider.hasLoadedOnce) {
            // Defensive copy: the fallback scan iterates asynchronously and
            // the cache list mutates on note writes.
            return List<Note>.of(appProvider.notes);
          }
          return getIt<DatabaseService>().getAllNotes();
        },
      ),
    );
  }

  // ============================================================
  // WAVE 4A: Storage services (no database dependency)
  // ============================================================
  if (!getIt.isRegistered<ModelStorageService>()) {
    getIt.registerLazySingleton<ModelStorageService>(
      () => ModelStorageService(),
    );
  }

  if (!getIt.isRegistered<ModelPreferenceService>()) {
    getIt.registerLazySingleton<ModelPreferenceService>(
      () => ModelPreferenceService(),
    );
  }

  if (!getIt.isRegistered<LocalModelService>()) {
    getIt.registerLazySingleton<LocalModelService>(() => LocalModelService());
  }

  if (!getIt.isRegistered<ModelSelector>()) {
    getIt.registerLazySingleton<ModelSelector>(
      () => ModelSelector(
        getIt<ModelStorageService>(),
        getIt<ModelPreferenceService>(),
      ),
    );
  }

  if (!getIt.isRegistered<SqlQueryService>()) {
    getIt.registerLazySingleton<SqlQueryService>(
      () => SqlQueryService(
        getIt<DatabaseService>(),
        changeNotifier: getIt<DataChangeNotifier>(),
      ),
    );
  }

  if (!getIt.isRegistered<AIService>()) {
    getIt.registerLazySingleton<AIService>(
      () => AIService(getIt<DatabaseService>(), getIt<ModelSelector>()),
    );
  }

  // ============================================================
  // WAVE 5: Services depending on AIService
  // ============================================================
  if (!getIt.isRegistered<UserAppService>()) {
    getIt.registerLazySingleton<UserAppService>(
      () => UserAppService(getIt<DatabaseService>(), getIt<AIService>()),
    );
  }

  if (!getIt.isRegistered<ContextManagerService>()) {
    getIt.registerLazySingleton<ContextManagerService>(
      () => ContextManagerService(getIt<ModelSelector>(), getIt<AIService>()),
    );
  }
  if (!getIt.isRegistered<AgentService>()) {
    getIt.registerLazySingleton<AgentService>(
      () => AgentService(
        getIt<ContextManagerService>(),
        getIt<ModelSelector>(),
        getIt<AIService>(),
        getIt<DatabaseService>(),
      ),
    );
  }

  // ============================================================
  // WAVE 6: Composite orchestrators
  // ============================================================
  if (!getIt.isRegistered<ForkService>()) {
    // ForkService is itself a singleton via factory; registration here is
    // so getIt<ForkService>() works (e.g. ChatPanel reaches for it via
    // getIt to subscribe to forkCreatedStream).
    getIt.registerLazySingleton<ForkService>(() => ForkService());
  }
  if (!getIt.isRegistered<MarkerChatSendService>()) {
    getIt.registerLazySingleton<MarkerChatSendService>(
      () => MarkerChatSendService(),
    );
  }

  // ============================================================
  // WAVE 7: Cloud sync (M2.9)
  // ============================================================
  // Registered as lazy singletons so the OAuth token manager (and with it
  // `OAuthTokenManager`'s per-instance in-flight-refresh de-duplication) and
  // the cached Drive root-folder ID inside `GoogleDriveBackend` are shared
  // by every caller, rather than each screen/tap building its own.
  if (!getIt.isRegistered<GoogleDriveAuthService>()) {
    getIt.registerLazySingleton<GoogleDriveAuthService>(
      () => GoogleDriveAuthService(),
    );
  }

  if (!getIt.isRegistered<CloudSyncService>()) {
    getIt.registerLazySingleton<CloudSyncService>(
      () => CloudSyncService(
        getIt<DatabaseService>(),
        authService: getIt<GoogleDriveAuthService>(),
      ),
    );
  }

  registerWorldClipServices();
}

/// World Clip services. Called from setupServiceLocator(); separated so tests
/// can register just this slice.
void registerWorldClipServices() {
  if (!getIt.isRegistered<FrameCorrection>()) {
    getIt.registerLazySingleton<FrameCorrection>(() => OpenCvFrameCorrection());
  }
  if (!getIt.isRegistered<VideoSource>()) {
    getIt.registerLazySingleton<VideoSource>(() => GalleryVideoSource());
  }
  if (!getIt.isRegistered<ScreenCaptureService>()) {
    getIt.registerLazySingleton<ScreenCaptureService>(
      () => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? MethodChannelScreenCaptureService()
          : UnsupportedScreenCaptureService(),
    );
  }
}

/// Reset all registrations. USE ONLY IN TESTS.
///
/// Call this in setUp() before registering mock services:
///
/// ```dart
/// setUp(() async {
///   await resetForTesting();
///   getIt.registerSingleton<DatabaseService>(MockDatabaseService());
/// });
/// ```
@visibleForTesting
Future<void> resetForTesting() async {
  await getIt.reset();
}
