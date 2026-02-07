import 'package:shared_preferences/shared_preferences.dart';

const String _protocolPreferenceKey = 'network_protocol_preference';
const String _retryCountKey = 'network_retry_count';
const String _backoffBaseKey = 'network_backoff_base';
const String _timeoutKey = 'network_timeout';
const String _connectTimeoutKey = 'network_connect_timeout';

/// Network protocol preference for HTTP requests.
enum NetworkProtocolPreference {
  /// Start with HTTP/1.1, automatically upgrade to HTTP/3 when alt-svc header is detected.
  auto,

  /// Force HTTP/3 only. Falls back to HTTP/1.1 if HTTP/3 unavailable.
  http3Only,

  /// Force HTTP/1.1 only. Never use HTTP/3.
  http11Only,
}

/// Service to manage network settings persistence.
class NetworkSettingsService {
  /// Default protocol preference (auto-upgrade).
  static const NetworkProtocolPreference defaultProtocolPreference =
      NetworkProtocolPreference.auto;

  /// Default retry count.
  static const int defaultRetryCount = 3;

  /// Minimum retry count.
  static const int minRetryCount = 0;

  /// Maximum retry count.
  static const int maxRetryCount = 5;

  /// Default backoff base in seconds.
  static const int defaultBackoffBase = 2;

  /// Minimum backoff base in seconds.
  static const int minBackoffBase = 1;

  /// Maximum backoff base in seconds.
  static const int maxBackoffBase = 10;

  /// Default timeout in seconds (10 minutes).
  static const int defaultTimeout = 600;

  /// Minimum timeout in seconds (30 seconds).
  static const int minTimeout = 30;

  /// Maximum timeout in seconds (30 minutes).
  static const int maxTimeout = 1800;

  /// Default connect timeout in seconds (30 seconds).
  static const int defaultConnectTimeout = 30;

  /// Minimum connect timeout in seconds (5 seconds).
  static const int minConnectTimeout = 5;

  /// Maximum connect timeout in seconds (2 minutes).
  static const int maxConnectTimeout = 120;

  /// Get the current protocol preference.
  static Future<NetworkProtocolPreference> getProtocolPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_protocolPreferenceKey);
    if (value == null ||
        value < 0 ||
        value >= NetworkProtocolPreference.values.length) {
      return defaultProtocolPreference;
    }
    return NetworkProtocolPreference.values[value];
  }

  /// Set the protocol preference.
  static Future<void> setProtocolPreference(
    NetworkProtocolPreference preference,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_protocolPreferenceKey, preference.index);
  }

  /// Get the current retry count.
  static Future<int> getRetryCount() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_retryCountKey);
    if (value == null || value < minRetryCount || value > maxRetryCount) {
      return defaultRetryCount;
    }
    return value;
  }

  /// Set the retry count.
  static Future<void> setRetryCount(int count) async {
    final prefs = await SharedPreferences.getInstance();
    final clampedCount = count.clamp(minRetryCount, maxRetryCount);
    await prefs.setInt(_retryCountKey, clampedCount);
  }

  /// Get the current backoff base in seconds.
  static Future<int> getBackoffBase() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_backoffBaseKey);
    if (value == null || value < minBackoffBase || value > maxBackoffBase) {
      return defaultBackoffBase;
    }
    return value;
  }

  /// Set the backoff base in seconds.
  static Future<void> setBackoffBase(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    final clampedSeconds = seconds.clamp(minBackoffBase, maxBackoffBase);
    await prefs.setInt(_backoffBaseKey, clampedSeconds);
  }

  /// Get the current timeout in seconds.
  static Future<int> getTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_timeoutKey);
    if (value == null || value < minTimeout || value > maxTimeout) {
      return defaultTimeout;
    }
    return value;
  }

  /// Set the timeout in seconds.
  static Future<void> setTimeout(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    final clampedSeconds = seconds.clamp(minTimeout, maxTimeout);
    await prefs.setInt(_timeoutKey, clampedSeconds);
  }

  /// Get the current connect timeout in seconds.
  static Future<int> getConnectTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_connectTimeoutKey);
    if (value == null ||
        value < minConnectTimeout ||
        value > maxConnectTimeout) {
      return defaultConnectTimeout;
    }
    return value;
  }

  /// Set the connect timeout in seconds.
  static Future<void> setConnectTimeout(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    final clampedSeconds = seconds.clamp(minConnectTimeout, maxConnectTimeout);
    await prefs.setInt(_connectTimeoutKey, clampedSeconds);
  }
}
