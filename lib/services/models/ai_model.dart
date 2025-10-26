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

  /// Generate with function calling support
  /// Returns raw response data that may contain function calls
  Future<Map<String, dynamic>> generateWithTools(
    String prompt,
    List<PlatformFile> attachedFiles,
    List<Map<String, dynamic>> tools, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    // Default implementation just calls generateWithAttachments
    // Models that support function calling should override this
    final text = await generateWithAttachments(
      prompt,
      attachedFiles,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      requestId: requestId,
    );
    return {
      'text': text,
      'function_calls': null,
    };
  }

  /// Common utility methods for all AI models

  /// Get today's date, time, and timezone context string
  static String getTodayContext() {
    final now = DateTime.now();
    final localNow = now.toLocal();
    
    // Format date
    final dateStr = '${localNow.year}-${localNow.month.toString().padLeft(2, '0')}-${localNow.day.toString().padLeft(2, '0')}';
    
    // Format time
    final timeStr = '${localNow.hour.toString().padLeft(2, '0')}:${localNow.minute.toString().padLeft(2, '0')}:${localNow.second.toString().padLeft(2, '0')}';
    
    // Get timezone offset
    final offset = localNow.timeZoneOffset;
    final offsetHours = offset.inHours;
    final offsetMinutes = offset.inMinutes.remainder(60).abs();
    final offsetSign = offset.isNegative ? '-' : '+';
    final timezoneStr = 'UTC$offsetSign${offsetHours.abs().toString().padLeft(2, '0')}:${offsetMinutes.toString().padLeft(2, '0')}';
    
    return '\n\nCurrent date and time: $dateStr (${getDayOfWeek(localNow)}) $timeStr $timezoneStr';
  }

  /// Get day of week for a given date
  static String getDayOfWeek(DateTime date) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[date.weekday - 1];
  }
}
