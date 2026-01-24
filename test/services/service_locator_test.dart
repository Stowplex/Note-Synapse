import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  tearDown(() async {
    await GetIt.I.reset();
  });

  group('ServiceLocator', () {
    test('setupServiceLocator registers DatabaseService', () {
      setupServiceLocator();

      expect(GetIt.I.isRegistered<DatabaseService>(), isTrue);
    });

    test('resetForTesting clears all registrations', () async {
      setupServiceLocator();
      expect(GetIt.I.isRegistered<DatabaseService>(), isTrue);

      await resetForTesting();

      expect(GetIt.I.isRegistered<DatabaseService>(), isFalse);
    });

    test('getIt provides access to GetIt instance', () {
      expect(getIt, same(GetIt.I));
    });
  });
}
