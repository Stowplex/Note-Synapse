import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'database_service.dart';
import 'note_modification_service.dart';
import 'content_ingestion_service.dart';
import 'conversation_service.dart';

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
