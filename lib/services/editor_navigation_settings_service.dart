import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';

/// Persisted placement of the editor navigation pad.
///
/// Deliberately not registered in the service locator: this is a per-device UI
/// preference with no business logic, so it follows the same static shape as
/// [ConversationSettingsService] rather than being injected.
class EditorNavigationSettingsService {
  EditorNavigationSettingsService._();

  static const String _padOnLeftKey = 'editor_nav_pad_on_left';
  static const String _padVisibleKey = 'editor_nav_pad_visible';

  /// Whether the pad sits in the bottom-left corner instead of bottom-right.
  /// Right-handed placement is the default, matching where it has always been.
  static Future<bool> isPadOnLeft() async {
    return _readBool(_padOnLeftKey, false);
  }

  static Future<void> setPadOnLeft(bool value) async {
    await _writeBool(_padOnLeftKey, value);
  }

  /// Whether the pad should appear when the editor gains focus. The pad is the
  /// point of the feature, so it is on by default and stays off only once the
  /// user has dismissed it.
  static Future<bool> isPadVisible() async {
    return _readBool(_padVisibleKey, true);
  }

  static Future<void> setPadVisible(bool value) async {
    await _writeBool(_padVisibleKey, value);
  }

  static Future<bool> _readBool(String key, bool fallback) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key) ?? fallback;
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to read editor navigation settings: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return fallback;
    }
  }

  static Future<void> _writeBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to save editor navigation settings: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}
