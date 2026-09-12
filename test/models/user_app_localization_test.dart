import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/user_app.dart';

void main() {
  UserApp app({Map<String, UserAppLocalizedMetadata> i18n = const {}}) {
    return UserApp(
      id: 'app',
      uuid: 'uuid',
      name: 'Diagram Studio',
      description: 'Create diagrams.',
      steps: const [],
      htmlContent: '<html></html>',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      i18n: i18n,
    );
  }

  group('UserApp localized metadata', () {
    test('uses exact locale, language fallback, then base metadata', () {
      final localized = app(
        i18n: const {
          'zh-CN': UserAppLocalizedMetadata(
            name: '图表工作室',
            description: '创建图表。',
          ),
          'zh': UserAppLocalizedMetadata(name: '图表'),
        },
      );

      expect(localized.nameForTag('zh-CN'), '图表工作室');
      expect(localized.descriptionForTag('zh_CN'), '创建图表。');
      expect(localized.nameForTag('zh-Hans-CN'), '图表');
      expect(localized.descriptionForTag('zh-Hans-CN'), 'Create diagrams.');
      expect(localized.nameForTag('en-US'), 'Diagram Studio');
    });

    test(
      'JSON round trip normalizes locale keys and ignores malformed data',
      () {
        final decoded = UserApp.fromJson({
          ...app().toJson(),
          'i18n': {
            'ZH_cn': {'name': ' 图表工作室 ', 'description': ' 创建图表。 '},
            'bad': 'not a map',
            'empty': {'name': '   '},
          },
        });

        expect(decoded.i18n.keys, ['zh-CN']);
        expect(decoded.nameForTag('zh-CN'), '图表工作室');
        expect(decoded.toJson()['i18n'], {
          'zh-CN': {'name': '图表工作室', 'description': '创建图表。'},
        });
      },
    );

    test('search metadata includes every locale', () {
      final localized = app(
        i18n: const {
          'zh-CN': UserAppLocalizedMetadata(name: '大爆炸', description: '空间画板'),
        },
      );

      expect(localized.searchableMetadata, containsAll(['大爆炸', '空间画板']));
    });
  });
}
