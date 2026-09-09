import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations_en.dart';
import 'package:note_synapse/l10n/app_localizations_zh.dart';
import 'package:note_synapse/utils/date_utils.dart';

void main() {
  group('AppDateUtils.formatRelative', () {
    final l10n = AppLocalizationsEn();
    final now = DateTime(2026, 9, 6, 12, 0, 0);

    String format(Duration ago) =>
        AppDateUtils.formatRelative(now.subtract(ago), l10n, now: now);

    test('is "just now" under a minute', () {
      expect(format(Duration.zero), 'Just now');
      expect(format(const Duration(seconds: 59)), 'Just now');
    });

    test('switches units at exact boundaries', () {
      expect(format(const Duration(minutes: 1)), '1m ago');
      expect(format(const Duration(minutes: 59, seconds: 59)), '59m ago');
      expect(format(const Duration(hours: 1)), '1h ago');
      expect(format(const Duration(hours: 23, minutes: 59)), '23h ago');
      expect(format(const Duration(days: 1)), '1d ago');
      expect(format(const Duration(days: 14, hours: 23)), '14d ago');
    });

    test('treats future times as just now', () {
      expect(format(const Duration(minutes: -5)), 'Just now');
    });

    test('defaults now to the current time', () {
      expect(
        AppDateUtils.formatRelative(
          DateTime.now().subtract(const Duration(hours: 3)),
          l10n,
        ),
        '3h ago',
      );
    });

    test('is localized', () {
      final zh = AppLocalizationsZh();
      String formatZh(Duration ago) =>
          AppDateUtils.formatRelative(now.subtract(ago), zh, now: now);

      expect(formatZh(Duration.zero), '刚刚');
      expect(formatZh(const Duration(minutes: 5)), '5分钟前');
      expect(formatZh(const Duration(hours: 3)), '3小时前');
      expect(formatZh(const Duration(days: 14)), '14天前');
    });
  });
}
