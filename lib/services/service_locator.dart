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
import 'sql_query_service.dart';
import 'context_manager_service.dart';
import 'ai_service.dart';
import 'agent_service.dart';
import 'mcp_service.dart';
import 'tag_image_service.dart';
import 'note_marker_service.dart';

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
  if (!getIt.isRegistered<DatabaseService>()) {
    getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  }

  if (!getIt.isRegistered<McpService>()) {
    getIt.registerLazySingleton<McpService>(() => McpService());
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
