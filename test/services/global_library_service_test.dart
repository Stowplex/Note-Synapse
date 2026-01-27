import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/global_library_service.dart';

void main() {
  group('GlobalLibraryAsset', () {
    test('constructor creates asset with required properties', () {
      final asset = GlobalLibraryAsset(
        path: '/path/to/script.js',
        type: 'script',
      );

      expect(asset.path, equals('/path/to/script.js'));
      expect(asset.type, equals('script'));
    });

    test('fromMap creates asset from map', () {
      final map = {'path': '/path/to/style.css', 'type': 'style'};
      final asset = GlobalLibraryAsset.fromMap(map);

      expect(asset.path, equals('/path/to/style.css'));
      expect(asset.type, equals('style'));
    });

    test('toMap serializes asset correctly', () {
      final asset = GlobalLibraryAsset(path: '/lib/main.js', type: 'script');
      final map = asset.toMap();

      expect(map['path'], equals('/lib/main.js'));
      expect(map['type'], equals('script'));
    });

    test('fromMap and toMap round-trip', () {
      final original = GlobalLibraryAsset(path: '/test/lib.js', type: 'script');
      final map = original.toMap();
      final restored = GlobalLibraryAsset.fromMap(map);

      expect(restored.path, equals(original.path));
      expect(restored.type, equals(original.type));
    });
  });

  group('GlobalLibrary', () {
    test('constructor creates library with required properties', () {
      final lib = GlobalLibrary(
        id: 'lib-001',
        name: 'Test Library',
        version: '1.0.0',
        description: 'A test library',
        usage: 'Include in your project',
        assets: [],
        isBuiltIn: true,
      );

      expect(lib.id, equals('lib-001'));
      expect(lib.name, equals('Test Library'));
      expect(lib.version, equals('1.0.0'));
      expect(lib.description, equals('A test library'));
      expect(lib.usage, equals('Include in your project'));
      expect(lib.assets, isEmpty);
      expect(lib.isBuiltIn, isTrue);
      expect(lib.isEnabled, isTrue); // default
    });

    test('constructor with isEnabled set to false', () {
      final lib = GlobalLibrary(
        id: 'lib-002',
        name: 'Disabled Library',
        version: '2.0.0',
        description: 'Disabled library',
        usage: 'N/A',
        assets: [],
        isBuiltIn: false,
        isEnabled: false,
      );

      expect(lib.isEnabled, isFalse);
    });

    test('constructor with assets', () {
      final assets = [
        GlobalLibraryAsset(path: '/lib/main.js', type: 'script'),
        GlobalLibraryAsset(path: '/lib/styles.css', type: 'style'),
      ];

      final lib = GlobalLibrary(
        id: 'lib-003',
        name: 'Multi-asset Library',
        version: '1.0.0',
        description: 'Has multiple assets',
        usage: 'Include all files',
        assets: assets,
        isBuiltIn: true,
      );

      expect(lib.assets.length, equals(2));
      expect(lib.assets[0].type, equals('script'));
      expect(lib.assets[1].type, equals('style'));
    });

    test('fromJson creates library correctly', () {
      final json = {
        'id': 'json-lib',
        'name': 'JSON Library',
        'version': '1.5.0',
        'description': 'Created from JSON',
        'usage': 'Load via JSON',
        'assets': [
          {'path': '/assets/lib.js', 'type': 'script'},
        ],
        'isBuiltIn': false,
        'isEnabled': true,
      };

      final lib = GlobalLibrary.fromJson(json);

      expect(lib.id, equals('json-lib'));
      expect(lib.name, equals('JSON Library'));
      expect(lib.version, equals('1.5.0'));
      expect(lib.isBuiltIn, isFalse);
      expect(lib.isEnabled, isTrue);
      expect(lib.assets.length, equals(1));
    });

    test('fromJson defaults isEnabled to true when missing', () {
      final json = {
        'id': 'partial-lib',
        'name': 'Partial Library',
        'version': '1.0.0',
        'description': 'Missing isEnabled',
        'usage': 'Test',
        'assets': [],
        'isBuiltIn': true,
        // isEnabled is missing
      };

      final lib = GlobalLibrary.fromJson(json);

      expect(lib.isEnabled, isTrue);
    });

    test('toJson serializes library correctly', () {
      final lib = GlobalLibrary(
        id: 'serialize-lib',
        name: 'Serialize Test',
        version: '2.0.0',
        description: 'Test serialization',
        usage: 'Serialize me',
        assets: [GlobalLibraryAsset(path: '/path/script.js', type: 'script')],
        isBuiltIn: false,
        isEnabled: false,
      );

      final json = lib.toJson();

      expect(json['id'], equals('serialize-lib'));
      expect(json['name'], equals('Serialize Test'));
      expect(json['version'], equals('2.0.0'));
      expect(json['description'], equals('Test serialization'));
      expect(json['usage'], equals('Serialize me'));
      expect(json['isBuiltIn'], isFalse);
      expect(json['isEnabled'], isFalse);
      expect((json['assets'] as List).length, equals(1));
    });

    test('fromJson and toJson round-trip', () {
      final original = GlobalLibrary(
        id: 'roundtrip-lib',
        name: 'Roundtrip',
        version: '3.0.0',
        description: 'Test roundtrip',
        usage: 'Round and round',
        assets: [
          GlobalLibraryAsset(path: '/a.js', type: 'script'),
          GlobalLibraryAsset(path: '/b.css', type: 'style'),
        ],
        isBuiltIn: false,
        isEnabled: true,
      );

      final json = original.toJson();
      final restored = GlobalLibrary.fromJson(json);

      expect(restored.id, equals(original.id));
      expect(restored.name, equals(original.name));
      expect(restored.version, equals(original.version));
      expect(restored.isBuiltIn, equals(original.isBuiltIn));
      expect(restored.isEnabled, equals(original.isEnabled));
      expect(restored.assets.length, equals(original.assets.length));
    });

    test('isEnabled is mutable', () {
      final lib = GlobalLibrary(
        id: 'mutable-lib',
        name: 'Mutable',
        version: '1.0.0',
        description: 'Test mutability',
        usage: 'Change me',
        assets: [],
        isBuiltIn: false,
        isEnabled: true,
      );

      expect(lib.isEnabled, isTrue);

      lib.isEnabled = false;

      expect(lib.isEnabled, isFalse);
    });
  });

  group('GlobalLibraryService', () {
    test('singleton instance is consistent', () {
      final instance1 = GlobalLibraryService();
      final instance2 = GlobalLibraryService();

      expect(identical(instance1, instance2), isTrue);
    });
  });
}
