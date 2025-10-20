import 'package:file_picker/file_picker.dart';
import '../../models/model_config.dart';

/// Base interface for AI models
abstract class AIModel {
  /// Model identifier
  String get id;

  /// Model display name
  String get name;

  /// Model description
  String get description;

  /// Check if model is ready to use
  Future<bool> isReady();

  /// Initialize the model
  Future<void> initialize({ModelConfig? config});

  /// Generate text with optional attachments
  Future<String> generateWithAttachments(
    String prompt,
    List<PlatformFile> attachedFiles, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  });


  /// Common utility methods for all AI models

  /// Get today's date context string
  static String getTodayContext() {
    final today = DateTime.now();
    return '\n\nToday\'s date: ${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')} (${getDayOfWeek(today)})';
  }

  /// Get day of week for a given date
  static String getDayOfWeek(DateTime date) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[date.weekday - 1];
  }
}
