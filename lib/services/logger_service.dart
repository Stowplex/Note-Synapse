import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class AiLogEntry {
  final String id;
  final String type; // 'request' or 'response'
  final String endpoint;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  AiLogEntry({
    required this.id,
    required this.type,
    required this.endpoint,
    required this.data,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'endpoint': endpoint,
    'data': data,
    'timestamp': timestamp.toIso8601String(),
  };
}

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

  // Global singleton log bucket for AI requests and responses
  static final List<AiLogEntry> _aiLogBucket = [];
  static const int _maxLogEntries = 100;

  static List<AiLogEntry> get aiLogBucket => List.unmodifiable(_aiLogBucket);

  static void clearAiLogBucket() {
    _aiLogBucket.clear();
  }

  static void _addToLogBucket(AiLogEntry entry) {
    _aiLogBucket.add(entry);
    if (_aiLogBucket.length > _maxLogEntries) {
      _aiLogBucket.removeAt(0); // Remove oldest entry
    }
  }

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
    _logger.w(message, error: error, stackTrace: stackTrace);
  }

  static void error(String message, {dynamic error, StackTrace? stackTrace}) {
    _logger.e(message, error: error, stackTrace: stackTrace);
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
    final requestIdStr =
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final timestamp = DateTime.now();

    if (kDebugMode) {
      _logger.d(
        '🤖 AI REQUEST [$requestIdStr]',
        error: {
          'endpoint': endpoint,
          'headers': headers,
          'body': requestBody,
          'timestamp': timestamp.toIso8601String(),
        },
      );
    }

    // Add to log bucket
    _addToLogBucket(
      AiLogEntry(
        id: requestIdStr,
        type: 'request',
        endpoint: endpoint,
        data: {'headers': headers, 'body': requestBody},
        timestamp: timestamp,
      ),
    );
  }

  static void logAiResponse({
    required int statusCode,
    required Map<String, String> headers,
    required dynamic responseBody,
    String? requestId,
    Duration? duration,
  }) {
    final requestIdStr =
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final durationStr = duration != null
        ? ' (${duration.inMilliseconds}ms)'
        : '';
    final timestamp = DateTime.now();

    if (kDebugMode) {
      _logger.d(
        '🤖 AI RESPONSE [$requestIdStr]$durationStr',
        error: {
          'statusCode': statusCode,
          'headers': headers,
          'body': responseBody,
          'timestamp': timestamp.toIso8601String(),
        },
      );
    }

    // Add to log bucket
    _addToLogBucket(
      AiLogEntry(
        id: requestIdStr,
        type: 'response',
        endpoint: '', // Will be filled by matching request if available
        data: {
          'statusCode': statusCode,
          'headers': headers,
          'body': responseBody,
          'duration': duration?.inMilliseconds,
        },
        timestamp: timestamp,
      ),
    );
  }

  static void logAiError({
    required String error,
    required String endpoint,
    String? requestId,
    Duration? duration,
  }) {
    final requestIdStr =
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final durationStr = duration != null
        ? ' (${duration.inMilliseconds}ms)'
        : '';
    final timestamp = DateTime.now();

    _logger.e(
      '🤖 AI ERROR [$requestIdStr]$durationStr',
      error: {
        'endpoint': endpoint,
        'error': error,
        'timestamp': timestamp.toIso8601String(),
      },
    );

    // Add to log bucket
    _addToLogBucket(
      AiLogEntry(
        id: requestIdStr,
        type: 'error',
        endpoint: endpoint,
        data: {'error': error, 'duration': duration?.inMilliseconds},
        timestamp: timestamp,
      ),
    );
  }

  static void logAiConsole({
    required String consoleOutput,
    required String endpoint,
    String? requestId,
    Duration? duration,
  }) {
    final requestIdStr =
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final timestamp = DateTime.now();

    // Add to log bucket
    _addToLogBucket(
      AiLogEntry(
        id: requestIdStr,
        type: 'console',
        endpoint: endpoint,
        data: {
          'consoleOutput': consoleOutput,
          'duration': duration?.inMilliseconds,
        },
        timestamp: timestamp,
      ),
    );
  }
}
