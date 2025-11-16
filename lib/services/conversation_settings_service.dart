import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';

class ConversationSettingsService {
  ConversationSettingsService._();

  static const String _maxToolIterationsKey =
      'conversation_max_tool_iterations';
  static const int defaultMaxToolIterations = 10;
  static const int minToolIterations = 1;
  static const int maxToolIterationsCap = 50;

  static Future<int> getMaxToolIterations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(_maxToolIterationsKey);
      if (stored == null) {
        return defaultMaxToolIterations;
      }
      return stored.clamp(minToolIterations, maxToolIterationsCap);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to read conversation settings: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return defaultMaxToolIterations;
    }
  }

  static Future<void> setMaxToolIterations(int value) async {
    final sanitized = value.clamp(minToolIterations, maxToolIterationsCap);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_maxToolIterationsKey, sanitized);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to save conversation settings: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
