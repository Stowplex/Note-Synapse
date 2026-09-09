import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';

import 'note_modification_space_test.mocks.dart';

/// M2: `NoteModificationService.createNote` files new notes into the active
/// Space; `buildNote` — which also backs previews — never does.
@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late DataChangeNotifier notifier;
  late SpaceScopeService scope;
  late NoteModificationService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    notifier = DataChangeNotifier();
    scope = SpaceScopeService();
    service = NoteModificationService(
      mockDb,
      changeNotifier: notifier,
      spaceScope: scope,
    );
    when(mockDb.insertNote(any)).thenAnswer((_) async => 'id');
  });

  Note captureInserted() =>
      verify(mockDb.insertNote(captureAny)).captured.single as Note;

  group('createNote', () {
    test('stamps the active space tags as an order-preserving union', () async {
      scope.setActive('s1', ['thesis', '2026']);

      await service.createNote({
        'title': 'Draft',
        'tags': ['reading', 'thesis'],
      });

      expect(captureInserted().tags, ['reading', 'thesis', '2026']);
    });

    test('stamps a note that carries no tags at all', () async {
      scope.setActive('s1', ['thesis']);

      await service.createNote({'title': 'Draft'});

      expect(captureInserted().tags, ['thesis']);
    });

    test('does not mutate the caller\'s data map', () async {
      scope.setActive('s1', ['thesis']);
      final data = <String, dynamic>{
        'title': 'Draft',
        'tags': <String>['reading'],
      };

      await service.createNote(data);

      expect(data['tags'], ['reading']);
    });

    test('is a no-op with no active space', () async {
      await service.createNote({
        'title': 'Draft',
        'tags': ['reading'],
      });

      expect(captureInserted().tags, ['reading']);
    });

    test('never adds all-spaces', () async {
      scope.setActive('s1', ['thesis']);

      await service.createNote({'title': 'Draft'});

      expect(
        captureInserted().tags,
        isNot(contains(SpaceScopeService.allSpacesTag)),
      );
    });

    test('an omitted scope falls back to the shared instance, exactly like '
        'the changeNotifier parameter', () async {
      // The five test files that construct this service positionally take this
      // path; a required scope parameter would break them at compile time.
      // Two sibling fallbacks that read the same state must behave the same:
      // a private `SpaceScopeService()` here would be permanently unset, so
      // the locator-built service would be the only one that ever stamps.
      getIt.registerSingleton<SpaceScopeService>(scope);
      scope.setActive('s1', ['thesis']);

      final bare = NoteModificationService(mockDb, changeNotifier: notifier);

      await bare.createNote({
        'title': 'Draft',
        'tags': ['reading'],
      });

      expect(captureInserted().tags, ['reading', 'thesis']);
    });

    test('the shared instance is registered on first use and reused', () {
      final first = SpaceScopeService.shared();
      expect(getIt.isRegistered<SpaceScopeService>(), isTrue);
      expect(identical(SpaceScopeService.shared(), first), isTrue);
      expect(identical(getIt<SpaceScopeService>(), first), isTrue);
    });
  });

  group('buildNote', () {
    test('does not stamp, even with a space active', () async {
      scope.setActive('s1', ['thesis']);

      final note = await service.buildNote({
        'title': 'Preview',
        'tags': ['reading'],
      });

      expect(note.tags, ['reading']);
      verifyNever(mockDb.insertNote(any));
    });

    test('does not stamp a tagless preview', () async {
      scope.setActive('s1', ['thesis']);

      final note = await service.buildNote({'title': 'Preview'});

      expect(note.tags, isEmpty);
    });
  });
}
