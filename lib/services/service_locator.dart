import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'database_service.dart';
import 'note_modification_service.dart';
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
import 'tts_service.dart';
import 'web_session_service.dart';
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

  if (!getIt.isRegistered<McpService>()) {
    getIt.registerLazySingleton<McpService>(() => McpService());
  }

  if (!getIt.isRegistered<WebSessionService>()) {
    getIt.registerLazySingleton<WebSessionService>(() => WebSessionService());
  }

  if (!getIt.isRegistered<TtsService>()) {
    getIt.registerLazySingleton<TtsService>(() => TtsService());
  }

  // ============================================================
  // WAVE 2: Simple services - Depend only on DatabaseService
  // ============================================================
  if (!getIt.isRegistered<NoteModificationService>()) {
    getIt.registerLazySingleton<NoteModificationService>(
      () => NoteModificationService(getIt<DatabaseService>()),
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
      () => SqlQueryService(getIt<DatabaseService>()),
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
    getIt.registerLazySingleton<ScreenCaptureService>(() =>
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? MethodChannelScreenCaptureService()
            : UnsupportedScreenCaptureService());
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
