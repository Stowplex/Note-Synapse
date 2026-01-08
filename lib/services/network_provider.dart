import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart';

import 'network_settings_service.dart';
import 'logger_service.dart';

/// Retriable HTTP status codes that warrant automatic retry.
/// - 408: Request Timeout
/// - 425: Too Early
/// - 429: Too Many Requests (rate limiting)
/// - 500: Internal Server Error
/// - 502: Bad Gateway
/// - 503: Service Unavailable
/// - 504: Gateway Timeout
const Set<int> retriableStatusCodes = {408, 425, 429, 500, 502, 503, 504};

/// Centralized network provider with HTTP/3 support, automatic protocol
/// negotiation, retry logic, and connection pooling.
class NetworkProvider {
  static NetworkProvider? _instance;

  /// HTTP/1.1 client (always available as fallback).
  RhttpCompatibleClient? _http11Client;

  /// HTTP/3 client (created when needed).
  RhttpCompatibleClient? _http3Client;

  /// Tracks which hosts support HTTP/3 (detected via alt-svc header).
  /// Key: host (e.g., "api.example.com"), Value: true if HTTP/3 supported.
  final Map<String, bool> _http3SupportedHosts = {};

  /// Tracks which hosts have failed HTTP/3 connections (fallback to HTTP/1.1).
  final Set<String> _http3FailedHosts = {};

  /// Current settings (cached for performance).
  NetworkProtocolPreference _protocolPreference =
      NetworkSettingsService.defaultProtocolPreference;
  int _retryCount = NetworkSettingsService.defaultRetryCount;
  int _backoffBase = NetworkSettingsService.defaultBackoffBase;

  /// Timer for idle connection cleanup.
  Timer? _idleCleanupTimer;

  /// Duration after which idle clients are disposed.
  static const Duration _idleTimeout = Duration(minutes: 5);

  /// Last request timestamp for idle detection.
  DateTime _lastRequestTime = DateTime.now();

  NetworkProvider._();

  /// Initialize the network provider. Must be called after Rhttp.init().
  static Future<void> init() async {
    _instance = NetworkProvider._();
    await _instance!._loadSettings();
    await _instance!._createHttp11Client();
    _instance!._startIdleCleanupTimer();
    LoggerService.info('NetworkProvider initialized');
  }

  /// Get the singleton instance.
  static NetworkProvider get instance {
    if (_instance == null) {
      throw StateError(
        'NetworkProvider not initialized. Call NetworkProvider.init() first.',
      );
    }
    return _instance!;
  }

  /// Reload settings from storage (call after settings change).
  Future<void> reloadSettings() async {
    await _loadSettings();
    LoggerService.info(
      'NetworkProvider settings reloaded: protocol=$_protocolPreference, '
      'retryCount=$_retryCount, backoffBase=$_backoffBase',
    );
  }

  Future<void> _loadSettings() async {
    _protocolPreference = await NetworkSettingsService.getProtocolPreference();
    _retryCount = await NetworkSettingsService.getRetryCount();
    _backoffBase = await NetworkSettingsService.getBackoffBase();
  }

  Future<void> _createHttp11Client() async {
    _http11Client?.close();
    _http11Client = await RhttpCompatibleClient.create(
      settings: const ClientSettings(
        httpVersionPref: HttpVersionPref.http1_1,
        timeoutSettings: TimeoutSettings(
          timeout: Duration(seconds: 120),
          connectTimeout: Duration(seconds: 30),
          keepAliveTimeout: Duration(seconds: 60),
          keepAlivePing: Duration(seconds: 30),
        ),
      ),
    );
  }

  Future<RhttpCompatibleClient> _getHttp3Client() async {
    if (_http3Client == null) {
      _http3Client = await RhttpCompatibleClient.create(
        settings: const ClientSettings(
          httpVersionPref: HttpVersionPref.http3,
          timeoutSettings: TimeoutSettings(
            timeout: Duration(seconds: 120),
            connectTimeout: Duration(seconds: 30),
            keepAliveTimeout: Duration(seconds: 60),
            keepAlivePing: Duration(seconds: 30),
          ),
        ),
      );
    }
    return _http3Client!;
  }

  void _startIdleCleanupTimer() {
    _idleCleanupTimer?.cancel();
    _idleCleanupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final idleDuration = DateTime.now().difference(_lastRequestTime);
      if (idleDuration > _idleTimeout) {
        _disposeIdleClients();
      }
    });
  }

  void _disposeIdleClients() {
    if (_http3Client != null) {
      LoggerService.debug('Closing idle HTTP/3 client');
      _http3Client?.close();
      _http3Client = null;
    }
  }

  /// Determine which client to use based on protocol preference and host capabilities.
  Future<RhttpCompatibleClient> _getClientForHost(String host) async {
    switch (_protocolPreference) {
      case NetworkProtocolPreference.http11Only:
        return _http11Client!;

      case NetworkProtocolPreference.http3Only:
        // Try HTTP/3, but fall back if host has failed before
        if (_http3FailedHosts.contains(host)) {
          return _http11Client!;
        }
        return await _getHttp3Client();

      case NetworkProtocolPreference.auto:
        // Use HTTP/3 only if we've detected support via alt-svc
        if (_http3SupportedHosts[host] == true &&
            !_http3FailedHosts.contains(host)) {
          return await _getHttp3Client();
        }
        return _http11Client!;
    }
  }

  /// Check response headers for alt-svc indicating HTTP/3 support.
  void _checkAltSvcHeader(String host, http.Response response) {
    final altSvc = response.headers['alt-svc'];
    if (altSvc != null && altSvc.contains('h3')) {
      if (_http3SupportedHosts[host] != true) {
        LoggerService.info('HTTP/3 support detected for host: $host');
        _http3SupportedHosts[host] = true;
      }
    }
  }

  /// Perform a GET request with retry logic.
  static Future<http.Response> get(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    return instance._performRequest(() async {
      final client = await instance._getClientForHost(url.host);
      return client.get(url, headers: headers);
    }, url);
  }

  /// Perform a POST request with retry logic.
  static Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    String? encoding,
  }) async {
    return instance._performRequest(() async {
      final client = await instance._getClientForHost(url.host);
      return client.post(url, headers: headers, body: body);
    }, url);
  }

  /// Perform a PUT request with retry logic.
  static Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    return instance._performRequest(() async {
      final client = await instance._getClientForHost(url.host);
      return client.put(url, headers: headers, body: body);
    }, url);
  }

  /// Perform a DELETE request with retry logic.
  static Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    return instance._performRequest(() async {
      final client = await instance._getClientForHost(url.host);
      return client.delete(url, headers: headers, body: body);
    }, url);
  }

  /// Perform a HEAD request with retry logic.
  static Future<http.Response> head(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    return instance._performRequest(() async {
      final client = await instance._getClientForHost(url.host);
      return client.head(url, headers: headers);
    }, url);
  }

  /// Core request execution with retry logic.
  Future<http.Response> _performRequest(
    Future<http.Response> Function() requestFn,
    Uri url,
  ) async {
    _lastRequestTime = DateTime.now();

    int attempt = 0;
    http.Response? lastResponse;
    Object? lastError;

    while (attempt <= _retryCount) {
      try {
        final response = await requestFn();
        lastResponse = response;

        // Check for alt-svc header to detect HTTP/3 support
        _checkAltSvcHeader(url.host, response);

        // Check if we should retry based on status code
        if (retriableStatusCodes.contains(response.statusCode) &&
            attempt < _retryCount) {
          final delay = _calculateBackoff(attempt);
          LoggerService.warning(
            'Retriable status ${response.statusCode} for ${url.host}, '
            'attempt ${attempt + 1}/$_retryCount, retrying in ${delay.inMilliseconds}ms',
          );
          await Future.delayed(delay);
          attempt++;
          continue;
        }

        return response;
      } on RhttpException catch (e) {
        lastError = e;

        // If HTTP/3 failed, mark host and retry with HTTP/1.1
        if (_protocolPreference != NetworkProtocolPreference.http11Only &&
            !_http3FailedHosts.contains(url.host) &&
            (_http3SupportedHosts[url.host] == true ||
                _protocolPreference == NetworkProtocolPreference.http3Only)) {
          LoggerService.warning(
            'HTTP/3 failed for ${url.host}, falling back to HTTP/1.1: $e',
          );
          _http3FailedHosts.add(url.host);
          // Retry immediately with HTTP/1.1
          continue;
        }

        if (attempt < _retryCount) {
          final delay = _calculateBackoff(attempt);
          LoggerService.warning(
            'Request failed for ${url.host}, attempt ${attempt + 1}/$_retryCount, '
            'retrying in ${delay.inMilliseconds}ms: $e',
          );
          await Future.delayed(delay);
          attempt++;
          continue;
        }
        rethrow;
      } catch (e) {
        lastError = e;

        if (attempt < _retryCount) {
          final delay = _calculateBackoff(attempt);
          LoggerService.warning(
            'Request failed for ${url.host}, attempt ${attempt + 1}/$_retryCount, '
            'retrying in ${delay.inMilliseconds}ms: $e',
          );
          await Future.delayed(delay);
          attempt++;
          continue;
        }
        rethrow;
      }
    }

    // Should not reach here, but just in case
    if (lastResponse != null) {
      return lastResponse;
    }
    throw lastError ?? Exception('Request failed after $_retryCount retries');
  }

  /// Calculate exponential backoff delay.
  /// Pattern: base, 2*base, 4*base, 8*base, ...
  Duration _calculateBackoff(int attempt) {
    final multiplier = 1 << attempt; // 2^attempt
    return Duration(seconds: _backoffBase * multiplier);
  }

  /// Dispose all resources.
  static void dispose() {
    _instance?._idleCleanupTimer?.cancel();
    _instance?._http11Client?.close();
    _instance?._http3Client?.close();
    _instance = null;
    LoggerService.info('NetworkProvider disposed');
  }
}
