import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/starter_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StarterService', () {
    group('Constants', () {
      test('userManualUuid has expected value', () {
        expect(
          StarterService.userManualUuid,
          equals('00000000-0000-0000-0000-000000000001'),
        );
      });

      test('userManualYamlPath has expected value', () {
        expect(
          StarterService.userManualYamlPath,
          equals('assets/starter/USER_MANUAL.yaml'),
        );
      });

      test('userManualPdfPath has expected value', () {
        expect(
          StarterService.userManualPdfPath,
          equals('assets/starter/USER_MANUAL.pdf'),
        );
      });

      test('starterAppsPath has expected value', () {
        expect(StarterService.starterAppsPath, equals('assets/starter/apps'));
      });
    });

    group('parseVersionFromNoteContent', () {
      test('extracts version from content', () {
        const content = '''version: 1.2.3
last updated: 2024-01-15

Some note content here.''';
        final version = StarterService.parseVersionFromNoteContent(content);
        expect(version, equals('1.2.3'));
      });

      test('returns null for content without version', () {
        const content = 'Just some regular content without version info.';
        final version = StarterService.parseVersionFromNoteContent(content);
        expect(version, isNull);
      });

      test('extracts version with spaces', () {
        const content = 'version:   2.0.0  \nother stuff';
        final version = StarterService.parseVersionFromNoteContent(content);
        expect(version, equals('2.0.0'));
      });

      test('handles version with build number', () {
        const content = 'version: 1.0.0+5\nmore content';
        final version = StarterService.parseVersionFromNoteContent(content);
        expect(version, equals('1.0.0+5'));
      });
    });

    group('isNewerVersion', () {
      test('returns true when major version is higher', () {
        expect(StarterService.isNewerVersion('2.0.0', '1.0.0'), isTrue);
      });

      test('returns true when minor version is higher', () {
        expect(StarterService.isNewerVersion('1.2.0', '1.1.0'), isTrue);
      });

      test('returns true when patch version is higher', () {
        expect(StarterService.isNewerVersion('1.0.2', '1.0.1'), isTrue);
      });

      test('returns false when versions are equal', () {
        expect(StarterService.isNewerVersion('1.0.0', '1.0.0'), isFalse);
      });

      test('returns false when old version is higher', () {
        expect(StarterService.isNewerVersion('1.0.0', '2.0.0'), isFalse);
      });

      test('handles version with build number', () {
        expect(StarterService.isNewerVersion('1.1.0+10', '1.0.0+50'), isTrue);
      });

      test('handles short versions', () {
        expect(StarterService.isNewerVersion('2.0', '1.0'), isTrue);
      });

      test('handles single digit versions', () {
        expect(StarterService.isNewerVersion('2', '1'), isTrue);
      });

      test('returns false for invalid version strings', () {
        expect(StarterService.isNewerVersion('invalid', '1.0.0'), isFalse);
      });
    });

    group('getAppTypeExplanation', () {
      test('returns explanation for normal type', () {
        expect(
          StarterService.getAppTypeExplanation('normal'),
          equals('A standalone web application'),
        );
      });

      test('returns explanation for note_action type', () {
        expect(
          StarterService.getAppTypeExplanation('note_action'),
          equals('Operates on pre-selected notes'),
        );
      });

      test('returns explanation for ai_tool type', () {
        expect(
          StarterService.getAppTypeExplanation('ai_tool'),
          equals('Exposes custom functions for AI to call'),
        );
      });

      test('returns unknown for unrecognized type', () {
        expect(
          StarterService.getAppTypeExplanation('something_else'),
          equals('Unknown type'),
        );
      });

      test('handles uppercase type', () {
        expect(
          StarterService.getAppTypeExplanation('NORMAL'),
          equals('A standalone web application'),
        );
      });

      test('handles mixed case type', () {
        expect(
          StarterService.getAppTypeExplanation('Note_Action'),
          equals('Operates on pre-selected notes'),
        );
      });
    });
  });
}
