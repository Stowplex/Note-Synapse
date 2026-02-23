import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/tag.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/tag_image_service.dart';

@GenerateMocks([DatabaseService])
import 'tag_image_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late TagImageService service;

  final testTags = [
    Tag(
      id: 'tag1',
      name: 'Alpha',
      color: '#FF0000',
      createdAt: DateTime(2026, 1, 1),
    ),
    Tag(
      id: 'tag2',
      name: 'Beta',
      color: '#00FF00',
      createdAt: DateTime(2026, 1, 2),
    ),
    Tag(
      id: 'tag3',
      name: 'Gamma',
      color: '#0000FF',
      createdAt: DateTime(2026, 1, 3),
    ),
  ];

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = TagImageService(mockDb);
  });

  group('loadAll', () {
    test('loads tag images and builds name-to-path map', () async {
      when(mockDb.getAllTagImages()).thenAnswer(
        (_) async => {
          'tag1': 'builtin:nature',
          'tag2': 'attachments/custom.png',
        },
      );
      when(mockDb.getAllTags()).thenAnswer((_) async => testTags);

      await service.loadAll();

      expect(service.getImagePathForTag('Alpha'), 'builtin:nature');
      expect(service.getImagePathForTag('Beta'), 'attachments/custom.png');
      expect(service.getImagePathForTag('Gamma'), isNull);
    });

    test('skips tag images for tags that no longer exist', () async {
      when(mockDb.getAllTagImages()).thenAnswer(
        (_) async => {'tag1': 'builtin:nature', 'deleted_tag': 'builtin:old'},
      );
      when(mockDb.getAllTags()).thenAnswer((_) async => testTags);

      await service.loadAll();

      expect(service.getImagePathForTag('Alpha'), 'builtin:nature');
      // deleted_tag has no corresponding tag name, so no mapping
    });
  });

  group('getImagePathsForTags', () {
    setUp(() async {
      when(mockDb.getAllTagImages()).thenAnswer(
        (_) async => {
          'tag1': 'builtin:nature',
          'tag2': 'attachments/custom.png',
          'tag3': 'builtin:work',
        },
      );
      when(mockDb.getAllTags()).thenAnswer((_) async => testTags);
      await service.loadAll();
    });

    test('returns images sorted alphabetically, max 2', () {
      final paths = service.getImagePathsForTags(['Gamma', 'Beta', 'Alpha']);

      // Alphabetical: Alpha, Beta, Gamma -> take first 2
      expect(paths.length, 2);
      expect(paths[0], 'builtin:nature'); // Alpha
      expect(paths[1], 'attachments/custom.png'); // Beta
    });

    test('skips tags without images', () {
      // Only Alpha and Gamma have images; Beta is not in the query
      when(mockDb.getAllTagImages()).thenAnswer(
        (_) async => {'tag1': 'builtin:nature', 'tag3': 'builtin:work'},
      );

      // Use existing cache from setUp (all 3 tags have images)
      // Let's test with a tag that doesn't have an image
      final service2 = TagImageService(mockDb);
      // service2 has empty cache, so no tags have images
      final paths = service2.getImagePathsForTags(['Alpha', 'Beta']);
      expect(paths, isEmpty);
    });

    test('returns empty when no tags have images', () {
      final service2 = TagImageService(mockDb);
      final paths = service2.getImagePathsForTags(['Alpha', 'Beta', 'Gamma']);
      expect(paths, isEmpty);
    });
  });

  group('setTagImage', () {
    test('updates cache after setting image and increments revision', () async {
      when(
        mockDb.setTagImage('tag1', 'builtin:ocean'),
      ).thenAnswer((_) async {});
      when(
        mockDb.getAllTagImages(),
      ).thenAnswer((_) async => {'tag1': 'builtin:ocean'});
      when(mockDb.getAllTags()).thenAnswer((_) async => testTags);

      final initialRevision = service.revision.value;
      await service.setTagImage('tag1', 'builtin:ocean');

      expect(service.getImagePathForTag('Alpha'), 'builtin:ocean');
      expect(service.revision.value, initialRevision + 1);
      verify(mockDb.setTagImage('tag1', 'builtin:ocean')).called(1);
    });
  });

  group('removeTagImage', () {
    test('updates cache after removing builtin image', () async {
      // Set up initial state
      when(
        mockDb.getAllTagImages(),
      ).thenAnswer((_) async => {'tag1': 'builtin:nature'});
      when(mockDb.getAllTags()).thenAnswer((_) async => testTags);
      await service.loadAll();
      expect(service.getImagePathForTag('Alpha'), 'builtin:nature');

      // Now remove it
      when(
        mockDb.getTagImage('tag1'),
      ).thenAnswer((_) async => 'builtin:nature');
      when(mockDb.removeTagImage('tag1')).thenAnswer((_) async {});
      when(mockDb.getAllTagImages()).thenAnswer((_) async => {});

      final revisionBefore = service.revision.value;
      await service.removeTagImage('tag1');

      expect(service.getImagePathForTag('Alpha'), isNull);
      expect(service.revision.value, revisionBefore + 1);
      verify(mockDb.removeTagImage('tag1')).called(1);
    });
  });

  group('builtinImages', () {
    test('returns non-empty list of builtins', () {
      expect(TagImageService.builtinImages, isA<List<String>>());
      expect(TagImageService.builtinImages, isNotEmpty);
    });
  });

  group('static helpers', () {
    test('isBuiltin correctly identifies builtin paths', () {
      expect(TagImageService.isBuiltin('builtin:nature'), isTrue);
      expect(TagImageService.isBuiltin('attachments/custom.png'), isFalse);
    });

    test('builtinAssetPath returns correct path', () {
      expect(
        TagImageService.builtinAssetPath('nature'),
        'assets/tag_images/nature.png',
      );
    });

    test('builtinName extracts name from builtin path', () {
      expect(TagImageService.builtinName('builtin:nature'), 'nature');
    });
  });

  group('revision', () {
    test('increments on setTagImage', () async {
      when(mockDb.setTagImage(any, any)).thenAnswer((_) async {});
      when(mockDb.getAllTagImages()).thenAnswer((_) async => {});
      when(mockDb.getAllTags()).thenAnswer((_) async => []);

      expect(service.revision.value, 0);
      await service.setTagImage('tag1', 'builtin:nature');
      expect(service.revision.value, 1);
      await service.setTagImage('tag2', 'builtin:work');
      expect(service.revision.value, 2);
    });

    test('increments on removeTagImage', () async {
      when(mockDb.getTagImage(any)).thenAnswer((_) async => 'builtin:nature');
      when(mockDb.removeTagImage(any)).thenAnswer((_) async {});
      when(mockDb.getAllTagImages()).thenAnswer((_) async => {});
      when(mockDb.getAllTags()).thenAnswer((_) async => []);

      expect(service.revision.value, 0);
      await service.removeTagImage('tag1');
      expect(service.revision.value, 1);
    });
  });
}
