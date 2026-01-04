import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';

/// Service for managing agent mode configuration settings.
/// Stores compaction threshold, finding limit, and finding max words.
class AgenticSettingsService {
  AgenticSettingsService._();

  // Keys
  static const String _compactionThresholdKey = 'agentic_compaction_threshold';
  static const String _findingLimitKey = 'agentic_finding_limit';
  static const String _findingMaxWordsKey = 'agentic_finding_max_words';

  // Defaults
  static const int defaultCompactionThreshold = 100000;
  static const int defaultFindingLimit = 10;
  static const int defaultFindingMaxWords = 500;

  // Constraints
  static const int minCompactionThreshold = 10000;
  static const int maxCompactionThreshold = 500000;
  static const int minFindingLimit = 1;
  static const int maxFindingLimit = 50;
  static const int minFindingMaxWords = 100;
  static const int maxFindingMaxWords = 2000;

  // ==========================================================================
  // Compaction Threshold
  // ==========================================================================

  /// Gets the compaction threshold (in tokens).
  /// Runtime should use: min(compactionThreshold, model.maxInputTokens)
  static Future<int> getCompactionThreshold() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(_compactionThresholdKey);
      if (stored == null) {
        return defaultCompactionThreshold;
      }
      return stored.clamp(minCompactionThreshold, maxCompactionThreshold);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to read compaction threshold: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return defaultCompactionThreshold;
    }
  }

  /// Sets the compaction threshold (in tokens).
  static Future<void> setCompactionThreshold(int value) async {
    final sanitized = value.clamp(
      minCompactionThreshold,
      maxCompactionThreshold,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_compactionThresholdKey, sanitized);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to save compaction threshold: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // ==========================================================================
  // Finding Limit
  // ==========================================================================

  /// Gets the maximum number of findings to extract per task.
  static Future<int> getFindingLimit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(_findingLimitKey);
      if (stored == null) {
        return defaultFindingLimit;
      }
      return stored.clamp(minFindingLimit, maxFindingLimit);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to read finding limit: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return defaultFindingLimit;
    }
  }

  /// Sets the maximum number of findings to extract per task.
  static Future<void> setFindingLimit(int value) async {
    final sanitized = value.clamp(minFindingLimit, maxFindingLimit);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_findingLimitKey, sanitized);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to save finding limit: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // ==========================================================================
  // Finding Max Words
  // ==========================================================================

  /// Gets the maximum words per finding (for bullet points details).
  static Future<int> getFindingMaxWords() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(_findingMaxWordsKey);
      if (stored == null) {
        return defaultFindingMaxWords;
      }
      return stored.clamp(minFindingMaxWords, maxFindingMaxWords);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to read finding max words: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return defaultFindingMaxWords;
    }
  }

  /// Sets the maximum words per finding (for bullet points details).
  static Future<void> setFindingMaxWords(int value) async {
    final sanitized = value.clamp(minFindingMaxWords, maxFindingMaxWords);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_findingMaxWordsKey, sanitized);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to save finding max words: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
