# DI Migration Waves 4-5 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate 8 services to dependency injection, enabling mock-based testing.

**Architecture:** Convert static methods to instance methods with constructor injection. Register services in GetIt service locator. Update all caller sites to use `getIt<Service>()`.

**Tech Stack:** Flutter/Dart, GetIt, Mockito

---

## Wave 4A: Model Infrastructure

### Task 1: ModelStorageService - Convert to Instance Methods

**Files:**
- Modify: `lib/services/model_storage_service.dart`
- Modify: `lib/services/service_locator.dart`

**Step 1: Update ModelStorageService class**

In `lib/services/model_storage_service.dart`, convert from static to instance:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/model_config.dart';

class ModelStorageService {
  static const String _activeModelIdKey = 'active_model_id';
  static const String _configuredModelsKey = 'configured_models';

  final FlutterSecureStorage _storage;

  ModelStorageService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  // Convert all static methods to instance methods by removing 'static' keyword
  // and changing _storage access from static const to instance field

  Future<ModelConfig?> getActiveModel() async {
    // ... existing implementation, replace _storage with this._storage
  }

  // ... repeat for all other methods
}
```

Key changes:
- Remove `static` from all methods
- Change `static const _storage` to instance field `final FlutterSecureStorage _storage`
- Add constructor with optional storage parameter for testing

**Step 2: Register in service_locator.dart**

Add to Wave 4A section in `lib/services/service_locator.dart`:

```dart
import 'model_storage_service.dart';

// In setupServiceLocator(), after Wave 3:

// ============================================================
// WAVE 4A: Model Infrastructure
// ============================================================
if (!getIt.isRegistered<ModelStorageService>()) {
  getIt.registerLazySingleton<ModelStorageService>(
    () => ModelStorageService(),
  );
}
```

**Step 3: Run analyzer**

Run: `flutter analyze lib/services/model_storage_service.dart`
Expected: Errors about callers using static access (this is expected, we'll fix in Task 1b)

**Step 4: Commit partial progress**

```bash
git add lib/services/model_storage_service.dart lib/services/service_locator.dart
git commit -m "feat(di): convert ModelStorageService to instance methods (callers pending)"
```

---

### Task 1b: Update ModelStorageService Callers

**Files:**
- Search and update all files calling `ModelStorageService.method()`

**Step 1: Find all callers**

Run: `grep -r "ModelStorageService\." lib/ --include="*.dart" -l`

**Step 2: Update each caller**

Pattern: `ModelStorageService.method()` → `getIt<ModelStorageService>().method()`

Add import where needed:
```dart
import 'package:note_synapse/services/service_locator.dart';
```

**Step 3: Run analyzer**

Run: `flutter analyze`
Expected: No errors

**Step 4: Run tests**

Run: `flutter test`
Expected: All tests pass

**Step 5: Commit**

```bash
git add -A
git commit -m "feat(di): update all ModelStorageService callers to use getIt"
```

---

### Task 2: ModelPreferenceService - Convert to GetIt Singleton

**Files:**
- Modify: `lib/services/model_preference_service.dart`
- Modify: `lib/services/service_locator.dart`

**Step 1: Update ModelPreferenceService class**

In `lib/services/model_preference_service.dart`:

```dart
import 'package:shared_preferences/shared_preferences.dart';

class ModelPreferenceService {
  static const _preferenceListKey = 'model_preference_list';

  // Remove these lines:
  // ModelPreferenceService._();
  // static final instance = ModelPreferenceService._();

  /// Get ordered list of model IDs (preference order)
  Future<List<String>> getPreferenceList() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_preferenceListKey) ?? [];
  }

  /// Set the preference list (ordered by priority)
  Future<void> setPreferenceList(List<String> modelIds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_preferenceListKey, modelIds);
  }
}
```

**Step 2: Register in service_locator.dart**

Add after ModelStorageService:

```dart
import 'model_preference_service.dart';

if (!getIt.isRegistered<ModelPreferenceService>()) {
  getIt.registerLazySingleton<ModelPreferenceService>(
    () => ModelPreferenceService(),
  );
}
```

**Step 3: Update callers**

Pattern: `ModelPreferenceService.instance.method()` → `getIt<ModelPreferenceService>().method()`

Run: `grep -r "ModelPreferenceService\.instance" lib/ --include="*.dart" -l`

**Step 4: Run tests**

Run: `flutter test`
Expected: All tests pass

**Step 5: Commit**

```bash
git add -A
git commit -m "feat(di): migrate ModelPreferenceService to GetIt singleton"
```

---

### Task 3: ModelSelector - Convert to GetIt with Injected Dependencies

**Files:**
- Modify: `lib/services/model_selector.dart`
- Modify: `lib/services/service_locator.dart`
- Modify: `test/services/model_selector_test.dart`

**Step 1: Update ModelSelector class**

In `lib/services/model_selector.dart`:

```dart
import 'service_locator.dart';
import 'model_storage_service.dart';
import 'model_preference_service.dart';

class ModelSelector {
  final ModelStorageService _modelStorage;
  final ModelPreferenceService _modelPreference;

  // Remove these:
  // static ModelSelector? _instance;
  // static ModelSelector get instance => _instance ??= ModelSelector._();
  // ModelSelector._();

  ModelSelector(this._modelStorage, this._modelPreference);

  // Update methods to use injected services:
  // ModelStorageService.method() → _modelStorage.method()
  // ModelPreferenceService.instance.method() → _modelPreference.method()

  // Keep all existing instance methods
}
```

**Step 2: Register in service_locator.dart**

Add after ModelPreferenceService:

```dart
import 'model_selector.dart';

if (!getIt.isRegistered<ModelSelector>()) {
  getIt.registerLazySingleton<ModelSelector>(
    () => ModelSelector(
      getIt<ModelStorageService>(),
      getIt<ModelPreferenceService>(),
    ),
  );
}
```

**Step 3: Update callers**

Pattern: `ModelSelector.instance.method()` → `getIt<ModelSelector>().method()`

Run: `grep -r "ModelSelector\.instance" lib/ --include="*.dart" -l`

**Step 4: Update test file**

In `test/services/model_selector_test.dart`, add mock setup:

```dart
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/model_preference_service.dart';

@GenerateMocks([ModelStorageService, ModelPreferenceService])
import 'model_selector_test.mocks.dart';

void main() {
  late MockModelStorageService mockStorage;
  late MockModelPreferenceService mockPreference;
  late ModelSelector selector;

  setUp(() async {
    await resetForTesting();
    mockStorage = MockModelStorageService();
    mockPreference = MockModelPreferenceService();
    getIt.registerSingleton<ModelStorageService>(mockStorage);
    getIt.registerSingleton<ModelPreferenceService>(mockPreference);
    selector = ModelSelector(mockStorage, mockPreference);
  });

  tearDown(() async {
    await resetForTesting();
  });

  // ... existing tests, updated to use mocks
}
```

**Step 5: Generate mocks**

Run: `dart run build_runner build --delete-conflicting-outputs`

**Step 6: Run tests**

Run: `flutter test test/services/model_selector_test.dart`
Expected: All tests pass

**Step 7: Commit**

```bash
git add -A
git commit -m "feat(di): migrate ModelSelector to GetIt with injected dependencies"
```

---

### Task 4: SqlQueryService - Finalize DI

**Files:**
- Modify: `lib/services/sql_query_service.dart`
- Modify: `lib/services/service_locator.dart`
- Modify: `test/services/sql_query_service_test.dart`

**Step 1: Update SqlQueryService constructor**

In `lib/services/sql_query_service.dart`, change optional to required:

```dart
class SqlQueryService {
  final DatabaseService _databaseService;

  SqlQueryService(this._databaseService);

  // Remove the fallback pattern:
  // DatabaseService get _db => _injectedDatabaseService ?? getIt<DatabaseService>();
  // Just use _databaseService directly
}
```

**Step 2: Register in service_locator.dart**

Add to Wave 4A section:

```dart
import 'sql_query_service.dart';

if (!getIt.isRegistered<SqlQueryService>()) {
  getIt.registerLazySingleton<SqlQueryService>(
    () => SqlQueryService(getIt<DatabaseService>()),
  );
}
```

**Step 3: Update callers**

Find callers creating SqlQueryService directly and update to use getIt.

Run: `grep -r "SqlQueryService(" lib/ --include="*.dart" -l`

**Step 4: Update test file**

Ensure `test/services/sql_query_service_test.dart` uses mock injection pattern.

**Step 5: Run tests**

Run: `flutter test test/services/sql_query_service_test.dart`
Expected: All tests pass

**Step 6: Commit**

```bash
git add -A
git commit -m "feat(di): finalize SqlQueryService DI with required injection"
```

---

## Wave 4A Checkpoint

**Step 1: Run full test suite**

Run: `flutter test`
Expected: All tests pass

**Step 2: Run analyzer**

Run: `flutter analyze`
Expected: No errors (warnings OK)

**Step 3: Manual smoke test**

- Open app
- Go to Settings → Model configuration
- Verify model selection works

---

## Wave 4B: Context Layer

### Task 5: ContextManagerService - Inject ModelSelector

**Files:**
- Modify: `lib/services/context_manager_service.dart`
- Modify: `lib/services/service_locator.dart`
- Modify: `test/services/context_manager_service_test.dart`

**Step 1: Update ContextManagerService constructor**

In `lib/services/context_manager_service.dart`:

```dart
import 'service_locator.dart';
import 'model_selector.dart';

class ContextManagerService {
  final ModelSelector _modelSelector;

  ContextManagerService(this._modelSelector);

  // Update usages:
  // ModelSelector.instance.currentModelConfig → _modelSelector.currentModelConfig
}
```

**Step 2: Register in service_locator.dart**

Add Wave 4B section:

```dart
import 'context_manager_service.dart';

// ============================================================
// WAVE 4B: Context Layer
// ============================================================
if (!getIt.isRegistered<ContextManagerService>()) {
  getIt.registerLazySingleton<ContextManagerService>(
    () => ContextManagerService(getIt<ModelSelector>()),
  );
}
```

**Step 3: Update callers**

Pattern: `ContextManagerService()` → `getIt<ContextManagerService>()`

Run: `grep -r "ContextManagerService()" lib/ --include="*.dart" -l`

**Step 4: Update test file**

In `test/services/context_manager_service_test.dart`:

```dart
@GenerateMocks([ModelSelector])
import 'context_manager_service_test.mocks.dart';

void main() {
  late MockModelSelector mockModelSelector;
  late ContextManagerService service;

  setUp(() async {
    await resetForTesting();
    mockModelSelector = MockModelSelector();
    getIt.registerSingleton<ModelSelector>(mockModelSelector);
    service = ContextManagerService(mockModelSelector);
  });

  tearDown(() async {
    await resetForTesting();
  });
}
```

**Step 5: Generate mocks and run tests**

Run: `dart run build_runner build --delete-conflicting-outputs`
Run: `flutter test test/services/context_manager_service_test.dart`
Expected: All tests pass

**Step 6: Commit**

```bash
git add -A
git commit -m "feat(di): migrate ContextManagerService with injected ModelSelector"
```

---

## Wave 5A: AIService

### Task 6: AIService - Convert Static to Instance Methods

**Files:**
- Modify: `lib/services/ai_service.dart`
- Modify: `lib/services/service_locator.dart`

**Step 1: Update AIService class**

In `lib/services/ai_service.dart`:

```dart
import 'service_locator.dart';
import 'database_service.dart';
import 'model_selector.dart';

class AIService {
  final DatabaseService _db;
  final ModelSelector _modelSelector;

  AIService(this._db, this._modelSelector);

  // Convert all static methods to instance methods:
  // - Remove 'static' keyword from all methods
  // - Replace getIt<DatabaseService>() with _db
  // - Replace ModelSelector.instance with _modelSelector

  Future<void> initialize(AppProvider appProvider) async {
    // Update internal references
  }

  Future<String> generateWithAttachments(...) async {
    // ... existing implementation
  }

  // ... all other methods
}
```

**Step 2: Register in service_locator.dart**

Add Wave 5 section:

```dart
import 'ai_service.dart';

// ============================================================
// WAVE 5: Agent Layer
// ============================================================
if (!getIt.isRegistered<AIService>()) {
  getIt.registerLazySingleton<AIService>(
    () => AIService(
      getIt<DatabaseService>(),
      getIt<ModelSelector>(),
    ),
  );
}
```

**Step 3: Commit partial (callers pending)**

```bash
git add lib/services/ai_service.dart lib/services/service_locator.dart
git commit -m "feat(di): convert AIService to instance methods (callers pending)"
```

---

### Task 6b: Update AIService Callers

**Files:**
- All files calling `AIService.method()`

**Step 1: Find all callers**

Run: `grep -r "AIService\." lib/ --include="*.dart" -l`

**Step 2: Update each caller**

Pattern: `AIService.method()` → `getIt<AIService>().method()`

Add import where needed:
```dart
import 'package:note_synapse/services/service_locator.dart';
```

**Step 3: Update ContextManagerService**

Now that AIService is migrated, update ContextManagerService to inject it:

```dart
class ContextManagerService {
  final ModelSelector _modelSelector;
  final AIService _aiService;

  ContextManagerService(this._modelSelector, this._aiService);
}
```

Update registration:
```dart
getIt.registerLazySingleton<ContextManagerService>(
  () => ContextManagerService(
    getIt<ModelSelector>(),
    getIt<AIService>(),
  ),
);
```

**Step 4: Run analyzer and tests**

Run: `flutter analyze`
Run: `flutter test`
Expected: All pass

**Step 5: Commit**

```bash
git add -A
git commit -m "feat(di): update all AIService callers to use getIt"
```

---

## Wave 5B: AgentService

### Task 7: AgentService - Inject All Dependencies

**Files:**
- Modify: `lib/services/agent_service.dart`
- Modify: `lib/services/service_locator.dart`
- Modify: `test/services/agent_service_test.dart` (and related test files)

**Step 1: Update AgentService constructor**

In `lib/services/agent_service.dart`:

```dart
class AgentService extends ChangeNotifier {
  final ContextManagerService _contextManager;
  final ModelSelector _modelSelector;
  final AIService _aiService;
  final DatabaseService _db;

  AgentService(
    this._contextManager,
    this._modelSelector,
    this._aiService,
    this._db,
  );

  // Remove: final ContextManagerService _contextManager = ContextManagerService();
  // Update all usages:
  // - ModelSelector.instance → _modelSelector
  // - AIService.method() → _aiService.method()
  // - getIt<DatabaseService>() → _db
}
```

**Step 2: Register in service_locator.dart**

Add after AIService:

```dart
import 'agent_service.dart';

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
```

**Step 3: Update test files**

Update all agent_service test files with mock injection pattern:

```dart
@GenerateMocks([ContextManagerService, ModelSelector, AIService, DatabaseService])
import 'agent_service_test.mocks.dart';

setUp(() async {
  await resetForTesting();
  // Register all mocks
  getIt.registerSingleton<DatabaseService>(mockDb);
  getIt.registerSingleton<ModelSelector>(mockModelSelector);
  getIt.registerSingleton<AIService>(mockAiService);
  getIt.registerSingleton<ContextManagerService>(mockContextManager);

  agentService = AgentService(
    mockContextManager,
    mockModelSelector,
    mockAiService,
    mockDb,
  );
});
```

**Step 4: Generate mocks and run tests**

Run: `dart run build_runner build --delete-conflicting-outputs`
Run: `flutter test test/services/agent_service_test.dart`
Expected: All tests pass

**Step 5: Commit**

```bash
git add -A
git commit -m "feat(di): migrate AgentService with fully injected dependencies"
```

---

## Final Checkpoint

**Step 1: Run full test suite**

Run: `flutter test`
Expected: All tests pass

**Step 2: Run analyzer**

Run: `flutter analyze`
Expected: No errors

**Step 3: Manual smoke test**

- Open app
- Create a note
- Start an AI conversation
- Run an agent task
- Verify all features work

**Step 4: Final commit (if any cleanup needed)**

```bash
git add -A
git commit -m "chore: cleanup after DI migration waves 4-5"
```

---

## Summary

| Task | Service | Type |
|------|---------|------|
| 1 | ModelStorageService | static → instance |
| 2 | ModelPreferenceService | singleton → GetIt |
| 3 | ModelSelector | singleton → GetIt + inject |
| 4 | SqlQueryService | finalize injection |
| 5 | ContextManagerService | inject ModelSelector |
| 6 | AIService | static → instance |
| 7 | AgentService | inject all deps |

**Total: 7 tasks, 8 services migrated**
