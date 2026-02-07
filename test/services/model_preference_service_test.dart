import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:note_synapse/services/model_preference_service.dart';
import 'package:note_synapse/services/service_locator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ModelPreferenceService service;

  setUp(() async {
    await resetForTesting();
    FlutterSecureStorage.setMockInitialValues({});
    setupServiceLocator();
    SharedPreferences.setMockInitialValues({});
    service = getIt<ModelPreferenceService>();
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('ModelPreferenceService', () {
    test('getPreferenceList returns empty list when not set', () async {
      final result = await service.getPreferenceList();
      expect(result, isEmpty);
    });

    test('setPreferenceList and getPreferenceList round-trip', () async {
      final testList = ['model_1', 'model_2', 'model_3'];
      await service.setPreferenceList(testList);
      final result = await service.getPreferenceList();
      expect(result, equals(testList));
    });

    test('setPreferenceList overwrites existing list', () async {
      await service.setPreferenceList(['old_model']);
      await service.setPreferenceList(['new_model_1', 'new_model_2']);
      final result = await service.getPreferenceList();
      expect(result, equals(['new_model_1', 'new_model_2']));
    });

    test('setPreferenceList with empty list clears preferences', () async {
      await service.setPreferenceList(['model_1']);
      await service.setPreferenceList([]);
      final result = await service.getPreferenceList();
      expect(result, isEmpty);
    });

    test('getPreferenceList returns stored order', () async {
      final orderedList = ['z_model', 'a_model', 'm_model'];
      await service.setPreferenceList(orderedList);
      final result = await service.getPreferenceList();
      expect(result, equals(orderedList)); // Order preserved
    });

    test('setPreferenceList with single model', () async {
      await service.setPreferenceList(['only_model']);
      final result = await service.getPreferenceList();
      expect(result, equals(['only_model']));
    });

    test('getPreferenceList handles many models', () async {
      final manyModels = List.generate(20, (i) => 'model_$i');
      await service.setPreferenceList(manyModels);
      final result = await service.getPreferenceList();
      expect(result.length, equals(20));
      expect(result.first, equals('model_0'));
      expect(result.last, equals('model_19'));
    });
  });
}
