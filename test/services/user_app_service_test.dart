import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/user_app_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

@GenerateMocks([DatabaseService, AIService])
import 'user_app_service_test.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late MockDatabaseService mockDb;
  late MockAIService mockAi;
  late UserAppService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockAi = MockAIService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<AIService>(mockAi);
    service = UserAppService.createForTesting(mockDb, mockAi);
  });

  tearDown(() async {
    await resetForTesting();
  });

  UserApp createTestApp({
    String id = 'test-app-1',
    String uuid = 'test-uuid-1',
    String name = 'Test App',
    String description = 'A test app',
  }) {
    return UserApp(
      id: id,
      uuid: uuid,
      name: name,
      description: description,
      steps: [],
      htmlContent: '<html></html>',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  group('UserAppService CRUD operations', () {
    test('getAllUserApps returns empty list when no apps exist', () async {
      when(mockDb.getAllUserApps()).thenAnswer((_) async => []);

      final result = await service.getAllUserApps();

      expect(result, isEmpty);
      verify(mockDb.getAllUserApps()).called(1);
    });

    test('getAllUserApps returns apps from database', () async {
      final testApps = [
        createTestApp(id: 'app-1', name: 'App One'),
        createTestApp(id: 'app-2', name: 'App Two'),
      ];
      when(mockDb.getAllUserApps()).thenAnswer((_) async => testApps);

      final result = await service.getAllUserApps();

      expect(result.length, equals(2));
      expect(result[0].name, equals('App One'));
      expect(result[1].name, equals('App Two'));
      verify(mockDb.getAllUserApps()).called(1);
    });

    test('getAllUserApps returns empty list on error', () async {
      when(mockDb.getAllUserApps()).thenThrow(Exception('Database error'));

      final result = await service.getAllUserApps();

      expect(result, isEmpty);
      verify(mockDb.getAllUserApps()).called(1);
    });

    test('saveUserApp calls database insert', () async {
      final testApp = createTestApp();
      when(mockDb.insertUserApp(any)).thenAnswer((_) async => testApp.id);

      await service.saveUserApp(testApp);

      verify(mockDb.insertUserApp(testApp)).called(1);
    });

    test('saveUserApp rethrows database errors', () async {
      final testApp = createTestApp();
      when(mockDb.insertUserApp(any)).thenThrow(Exception('Insert failed'));

      expect(
        () => service.saveUserApp(testApp),
        throwsA(isA<Exception>()),
      );
      verify(mockDb.insertUserApp(testApp)).called(1);
    });

    test('updateUserApp calls database update', () async {
      final testApp = createTestApp();
      when(mockDb.updateUserApp(any)).thenAnswer((_) async {});

      await service.updateUserApp(testApp);

      verify(mockDb.updateUserApp(testApp)).called(1);
    });

    test('deleteUserApp calls database delete', () async {
      const appId = 'test-app-1';
      when(mockDb.deleteUserApp(any)).thenAnswer((_) async {});

      await service.deleteUserApp(appId);

      verify(mockDb.deleteUserApp(appId)).called(1);
    });
  });
}
