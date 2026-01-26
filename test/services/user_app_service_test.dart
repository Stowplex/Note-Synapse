import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/app_revision.dart';
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

  AppRevision createTestRevision({
    String id = 'test-revision-1',
    String appId = 'test-app-1',
    int revisionNumber = 1,
    String userPrompt = 'Test prompt',
    String aiResponse = 'Test response',
    String appCode = '<html><body>Test</body></html>',
    List<String> attachmentPaths = const [],
  }) {
    return AppRevision(
      id: id,
      appId: appId,
      revisionNumber: revisionNumber,
      revisionTimestamp: DateTime.now(),
      userPrompt: userPrompt,
      aiResponse: aiResponse,
      appCode: appCode,
      attachmentPaths: attachmentPaths,
    );
  }

  group('UserAppService state management', () {
    test('getAppState returns null for non-existent app', () async {
      when(mockDb.getUserAppState(any)).thenAnswer((_) async => null);

      final result = await service.getAppState('non-existent-app');

      expect(result, isNull);
      verify(mockDb.getUserAppState('non-existent-app')).called(1);
    });

    test('getAppState returns saved state', () async {
      final testState = {'key': 'value', 'count': 42};
      when(mockDb.getUserAppState(any)).thenAnswer((_) async => testState);

      final result = await service.getAppState('test-app-1');

      expect(result, equals(testState));
      expect(result!['key'], equals('value'));
      expect(result['count'], equals(42));
      verify(mockDb.getUserAppState('test-app-1')).called(1);
    });

    test('getAppState returns null on error', () async {
      when(mockDb.getUserAppState(any))
          .thenThrow(Exception('Database error'));

      final result = await service.getAppState('test-app-1');

      expect(result, isNull);
      verify(mockDb.getUserAppState('test-app-1')).called(1);
    });

    test('saveAppState persists state correctly', () async {
      final testState = {'key': 'value', 'count': 42};
      when(mockDb.updateUserAppState(any, any)).thenAnswer((_) async {});

      await service.saveAppState('test-app-1', testState);

      verify(mockDb.updateUserAppState('test-app-1', testState)).called(1);
    });

    test('saveAppState rethrows database errors', () async {
      final testState = {'key': 'value'};
      when(mockDb.updateUserAppState(any, any))
          .thenThrow(Exception('Database error'));

      expect(
        () => service.saveAppState('test-app-1', testState),
        throwsA(isA<Exception>()),
      );
      verify(mockDb.updateUserAppState('test-app-1', testState)).called(1);
    });
  });

  group('UserAppService revision management', () {
    test('getAppRevisions returns revisions for app', () async {
      final testRevisions = [
        createTestRevision(id: 'rev-1', revisionNumber: 1),
        createTestRevision(id: 'rev-2', revisionNumber: 2),
      ];
      when(mockDb.getAppRevisions(any)).thenAnswer((_) async => testRevisions);

      final result = await service.getAppRevisions('test-app-1');

      expect(result.length, equals(2));
      expect(result[0].id, equals('rev-1'));
      expect(result[1].id, equals('rev-2'));
      verify(mockDb.getAppRevisions('test-app-1')).called(1);
    });

    test('getAppRevisions returns empty list on error', () async {
      when(mockDb.getAppRevisions(any)).thenThrow(Exception('Database error'));

      final result = await service.getAppRevisions('test-app-1');

      expect(result, isEmpty);
      verify(mockDb.getAppRevisions('test-app-1')).called(1);
    });

    test('getAppRevision returns revision by id', () async {
      final testRevision = createTestRevision(id: 'rev-1');
      when(mockDb.getAppRevision(any)).thenAnswer((_) async => testRevision);

      final result = await service.getAppRevision('rev-1');

      expect(result, isNotNull);
      expect(result!.id, equals('rev-1'));
      verify(mockDb.getAppRevision('rev-1')).called(1);
    });

    test('getAppRevision returns null on error', () async {
      when(mockDb.getAppRevision(any)).thenThrow(Exception('Database error'));

      final result = await service.getAppRevision('rev-1');

      expect(result, isNull);
      verify(mockDb.getAppRevision('rev-1')).called(1);
    });

    test('deleteAppRevision calls database delete', () async {
      when(mockDb.deleteAppRevision(any)).thenAnswer((_) async {});

      await service.deleteAppRevision('rev-1');

      verify(mockDb.deleteAppRevision('rev-1')).called(1);
    });

    test('deleteAppRevision rethrows errors', () async {
      when(mockDb.deleteAppRevision(any))
          .thenThrow(Exception('Database error'));

      expect(
        () => service.deleteAppRevision('rev-1'),
        throwsA(isA<Exception>()),
      );
      verify(mockDb.deleteAppRevision('rev-1')).called(1);
    });

    test('setSelectedRevision updates app selected revision', () async {
      final testApp = createTestApp();
      when(mockDb.getUserApp(any)).thenAnswer((_) async => testApp);
      when(mockDb.updateUserApp(any)).thenAnswer((_) async {});

      await service.setSelectedRevision('test-app-1', 'rev-2');

      verify(mockDb.getUserApp('test-app-1')).called(1);
      verify(mockDb.updateUserApp(argThat(
        predicate<UserApp>((app) => app.selectedRevisionId == 'rev-2'),
      ))).called(1);
    });

    test('createInitialRevision creates revision with code', () async {
      final testApp = createTestApp();
      when(mockDb.getUserApp(any)).thenAnswer((_) async => testApp);
      when(mockDb.getAppRevisions(any)).thenAnswer((_) async => []);
      when(mockDb.insertAppRevision(any)).thenAnswer((_) async => 'new-rev-id');
      when(mockDb.updateUserApp(any)).thenAnswer((_) async {});

      final result = await service.createInitialRevision('test-app-1');

      expect(result, isNotNull);
      expect(result.appId, equals('test-app-1'));
      expect(result.revisionNumber, equals(1));
      expect(result.appCode, equals(testApp.htmlContent));
      expect(result.userPrompt, equals('Initial app creation'));
      verify(mockDb.getUserApp('test-app-1')).called(1);
      verify(mockDb.getAppRevisions('test-app-1')).called(1);
      verify(mockDb.insertAppRevision(any)).called(1);
      verify(mockDb.updateUserApp(argThat(
        predicate<UserApp>((app) => app.selectedRevisionId == result.id),
      ))).called(1);
    });

    test('createInitialRevision throws if app not found', () async {
      when(mockDb.getUserApp(any)).thenAnswer((_) async => null);

      expect(
        () => service.createInitialRevision('non-existent-app'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('App not found'),
        )),
      );
      verify(mockDb.getUserApp('non-existent-app')).called(1);
    });

    test('createInitialRevision throws if revisions already exist', () async {
      final testApp = createTestApp();
      final existingRevisions = [createTestRevision()];
      when(mockDb.getUserApp(any)).thenAnswer((_) async => testApp);
      when(mockDb.getAppRevisions(any))
          .thenAnswer((_) async => existingRevisions);

      await expectLater(
        () => service.createInitialRevision('test-app-1'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('already has revisions'),
        )),
      );
      verify(mockDb.getUserApp('test-app-1')).called(1);
      verify(mockDb.getAppRevisions('test-app-1')).called(1);
    });
  });
}
