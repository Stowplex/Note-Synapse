import 'package:shared_preferences/shared_preferences.dart';

const String _protocolPreferenceKey = 'network_protocol_preference';
const String _retryCountKey = 'network_retry_count';
const String _backoffBaseKey = 'network_backoff_base';

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
}
