import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'database_service.dart';

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

  // Future waves will be added here as services are migrated
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
