import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const _sensitiveRedactionZoneKey = #noteSynapseSensitiveLogRedaction;

  static bool get _redactSensitiveOperation =>
      Zone.current[_sensitiveRedactionZoneKey] == true;

  /// Runs [action] with payload logging disabled across its async call tree.
  /// Request/response metadata is retained, but bodies, console content, and
  /// exception strings are replaced. Protocol Study uses this after its exact
  /// outbound preview so approved fields do not leak into the global log UI.
  static Future<T> runWithSensitiveDataRedacted<T>(
    Future<T> Function() action,
  ) => runZoned(action, zoneValues: {_sensitiveRedactionZoneKey: true});

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

  /// Default max log entries (100). -1 = unlimited, 0 = disabled.
  static const int defaultMaxLogEntries = 100;
  static const String _maxLogEntriesKey = 'system_max_log_entries';

  /// Cached value for max log entries (loaded on first access).
  static int _cachedMaxLogEntries = defaultMaxLogEntries;
  static bool _maxLogEntriesLoaded = false;

  /// Gets the configured max log entries limit.
  /// -1 = unlimited, 0 = disabled, >0 = limit.
  static Future<int> getMaxLogEntries() async {
    if (!_maxLogEntriesLoaded) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final stored = prefs.getInt(_maxLogEntriesKey);
        _cachedMaxLogEntries = stored ?? defaultMaxLogEntries;
        _maxLogEntriesLoaded = true;
      } catch (e) {
        // Fallback to default
        _cachedMaxLogEntries = defaultMaxLogEntries;
      }
    }
    return _cachedMaxLogEntries;
  }

  /// Sets the max log entries limit.
  /// Use -1 for unlimited, 0 to disable logging.
  static Future<void> setMaxLogEntries(int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_maxLogEntriesKey, value);
      _cachedMaxLogEntries = value;
      _maxLogEntriesLoaded = true;

      // Apply the new limit immediately
      if (value == 0) {
        _aiLogBucket.clear();
      } else if (value > 0) {
        while (_aiLogBucket.length > value) {
          _aiLogBucket.removeAt(0);
        }
      }
    } catch (e) {
      // Ignore errors
    }
  }

  static List<AiLogEntry> get aiLogBucket => List.unmodifiable(_aiLogBucket);

  static void clearAiLogBucket() {
    _aiLogBucket.clear();
  }

  static void _addToLogBucket(AiLogEntry entry) {
    // Check if logging is disabled (0)
    if (_cachedMaxLogEntries == 0) return;

    _aiLogBucket.add(entry);

    // Trim if we have a limit (not -1 = unlimited)
    if (_cachedMaxLogEntries > 0 &&
        _aiLogBucket.length > _cachedMaxLogEntries) {
      _aiLogBucket.removeAt(0); // Remove oldest entry
    }
  }

  static void debug(String message, {dynamic error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      _logger.d(
        _redactSensitiveOperation
            ? 'Sensitive operation event (details redacted)'
            : message,
        error: _redactSensitiveOperation ? null : error,
        stackTrace: _redactSensitiveOperation ? null : stackTrace,
      );
    }
  }

  static void info(String message, {dynamic error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      _logger.i(
        _redactSensitiveOperation
            ? 'Sensitive operation event (details redacted)'
            : message,
        error: _redactSensitiveOperation ? null : error,
        stackTrace: _redactSensitiveOperation ? null : stackTrace,
      );
    }
  }

  static void warning(String message, {dynamic error, StackTrace? stackTrace}) {
    _logger.w(
      _redactSensitiveOperation
          ? 'Sensitive operation warning (details redacted)'
          : message,
      error: _redactSensitiveOperation ? null : error,
      stackTrace: _redactSensitiveOperation ? null : stackTrace,
    );
  }

  static void error(String message, {dynamic error, StackTrace? stackTrace}) {
    _logger.e(
      _redactSensitiveOperation
          ? 'Sensitive operation error (details redacted)'
          : message,
      error: _redactSensitiveOperation ? null : error,
      stackTrace: _redactSensitiveOperation ? null : stackTrace,
    );
  }

  static void verbose(String message, {dynamic error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      _logger.t(
        _redactSensitiveOperation
            ? 'Sensitive operation event (details redacted)'
            : message,
        error: _redactSensitiveOperation ? null : error,
        stackTrace: _redactSensitiveOperation ? null : stackTrace,
      );
    }
  }

  /// Header names whose values must never appear in logs or exports. Matched
  /// case-insensitively. Covers the common ways AI providers carry credentials
  /// (bearer tokens, provider-specific API-key headers) plus session cookies.
  static const Set<String> _sensitiveHeaderNames = {
    'authorization',
    'x-api-key',
    'api-key',
    'x-goog-api-key',
    'x-go-api-key',
    'openai-api-key',
    'anthropic-api-key',
    'cookie',
    'set-cookie',
    'proxy-authorization',
  };

  /// Returns a copy of [headers] with sensitive values replaced by `***`.
  static Map<String, String> _redactHeaders(Map<String, String> headers) {
    return headers.map((key, value) {
      if (_sensitiveHeaderNames.contains(key.toLowerCase())) {
        return MapEntry(key, '***REDACTED***');
      }
      return MapEntry(key, value);
    });
  }

  /// Strips query parameters from an endpoint URL, since some providers (e.g.
  /// Gemini) pass the API key as `?key=...`. Non-URL strings are returned as-is.
  static String _redactEndpoint(String endpoint) {
    if (endpoint.isEmpty) return endpoint;
    final uri = Uri.tryParse(endpoint);
    if (uri == null || uri.query.isEmpty) return endpoint;
    final queryStart = endpoint.indexOf('?');
    final fragmentStart = endpoint.indexOf('#', queryStart);
    return fragmentStart < 0
        ? endpoint.substring(0, queryStart)
        : '${endpoint.substring(0, queryStart)}${endpoint.substring(fragmentStart)}';
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
    final safeEndpoint = _redactEndpoint(endpoint);
    final safeHeaders = _redactHeaders(headers);

    final safeBody = _redactSensitiveOperation
        ? <String, dynamic>{
            'redacted': true,
            'topLevelKeys': requestBody.keys.toList(growable: false),
          }
        : requestBody;

    if (kDebugMode) {
      _logger.d(
        '🤖 AI REQUEST [$requestIdStr]',
        error: {
          'endpoint': safeEndpoint,
          'headers': safeHeaders,
          'body': safeBody,
          'timestamp': timestamp.toIso8601String(),
        },
      );
    }

    // Add to log bucket
    _addToLogBucket(
      AiLogEntry(
        id: requestIdStr,
        type: 'request',
        endpoint: safeEndpoint,
        data: {'headers': safeHeaders, 'body': safeBody},
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
    final safeHeaders = _redactHeaders(headers);

    final safeBody = _redactSensitiveOperation
        ? const <String, dynamic>{'redacted': true}
        : responseBody;

    if (kDebugMode) {
      _logger.d(
        '🤖 AI RESPONSE [$requestIdStr]$durationStr',
        error: {
          'statusCode': statusCode,
          'headers': safeHeaders,
          'body': safeBody,
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
          'headers': safeHeaders,
          'body': safeBody,
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
    final safeEndpoint = _redactEndpoint(endpoint);

    final safeError = _redactSensitiveOperation
        ? 'Sensitive AI call failed (details redacted)'
        : error;
    _logger.e(
      '🤖 AI ERROR [$requestIdStr]$durationStr',
      error: {
        'endpoint': safeEndpoint,
        'error': safeError,
        'timestamp': timestamp.toIso8601String(),
      },
    );

    // Add to log bucket
    _addToLogBucket(
      AiLogEntry(
        id: requestIdStr,
        type: 'error',
        endpoint: safeEndpoint,
        data: {'error': safeError, 'duration': duration?.inMilliseconds},
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
        endpoint: _redactEndpoint(endpoint),
        data: {
          'consoleOutput': _redactSensitiveOperation
              ? '<redacted>'
              : consoleOutput,
          'duration': duration?.inMilliseconds,
        },
        timestamp: timestamp,
      ),
    );
  }
}
