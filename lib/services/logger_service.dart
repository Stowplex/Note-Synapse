import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class LoggerService {
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  static void debug(String message, {dynamic error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      _logger.d(message, error: error, stackTrace: stackTrace);
    }
  }

  static void info(String message, {dynamic error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      _logger.i(message, error: error, stackTrace: stackTrace);
    }
  }

  static void warning(String message, {dynamic error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      _logger.w(message, error: error, stackTrace: stackTrace);
    }
  }

  static void error(String message, {dynamic error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      _logger.e(message, error: error, stackTrace: stackTrace);
    }
  }

  static void verbose(String message, {dynamic error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      _logger.t(message, error: error, stackTrace: stackTrace);
    }
  }

  // Specialized logging for AI requests and responses
  static void logAiRequest({
    required String endpoint,
    required Map<String, String> headers,
    required Map<String, dynamic> requestBody,
    String? requestId,
  }) {
    if (kDebugMode) {
      final requestIdStr = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      _logger.d('🤖 AI REQUEST [$requestIdStr]', error: {
        'endpoint': endpoint,
        'headers': headers,
        'body': requestBody,
        'timestamp': DateTime.now().toIso8601String(),
      });
    }
  }

  static void logAiResponse({
    required int statusCode,
    required Map<String, String> headers,
    required String responseBody,
    String? requestId,
    Duration? duration,
  }) {
    if (kDebugMode) {
      final requestIdStr = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final durationStr = duration != null ? ' (${duration.inMilliseconds}ms)' : '';
      
      _logger.d('🤖 AI RESPONSE [$requestIdStr]$durationStr', error: {
        'statusCode': statusCode,
        'headers': headers,
        'body': responseBody,
        'timestamp': DateTime.now().toIso8601String(),
      });
    }
  }

  static void logAiError({
    required String error,
    required String endpoint,
    String? requestId,
    Duration? duration,
  }) {
    if (kDebugMode) {
      final requestIdStr = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final durationStr = duration != null ? ' (${duration.inMilliseconds}ms)' : '';
      
      _logger.e('🤖 AI ERROR [$requestIdStr]$durationStr', error: {
        'endpoint': endpoint,
        'error': error,
        'timestamp': DateTime.now().toIso8601String(),
      });
    }
  }
}
