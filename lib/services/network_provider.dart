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
  int _timeout = NetworkSettingsService.defaultTimeout;
  int _connectTimeout = NetworkSettingsService.defaultConnectTimeout;

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
    // Recreate clients to apply new settings (especially timeout)
    await _createHttp11Client();
    // Close HTTP/3 client so it's recreated with new settings on next use
    _http3Client?.close();
    _http3Client = null;

    LoggerService.info(
      'NetworkProvider settings reloaded: protocol=$_protocolPreference, '
      'retryCount=$_retryCount, backoffBase=$_backoffBase, '
      'timeout=${_timeout}s, connectTimeout=${_connectTimeout}s',
    );
  }

  Future<void> _loadSettings() async {
    _protocolPreference = await NetworkSettingsService.getProtocolPreference();
    _retryCount = await NetworkSettingsService.getRetryCount();
    _backoffBase = await NetworkSettingsService.getBackoffBase();
    _timeout = await NetworkSettingsService.getTimeout();
    _connectTimeout = await NetworkSettingsService.getConnectTimeout();
  }

  /// How long a replaced HTTP/1.1 client is kept alive before being closed,
  /// so requests already in flight on it can finish. See
  /// [_createHttp11Client].
  static const Duration _retiredClientGrace = Duration(seconds: 30);

  /// Builds a new HTTP/1.1 client and swaps it in **before** retiring the
  /// old one.
  ///
  /// The previous implementation closed first and awaited the replacement
  /// second, which opened a window with two distinct problems: (a)
  /// `_http11Client` was null while the new client was being created, so
  /// `_getClientForHost`'s `_http11Client!` and [http11Client] could throw;
  /// and (b) `RhttpCompatibleClient.close()` is
  /// `dispose(cancelRunningRequests: true)` — it actively aborts in-flight
  /// requests, so any request already running (a Drive blob upload, say)
  /// died as a `ClientException` the moment the user changed an unrelated
  /// network setting. Building first, swapping, then retiring the old
  /// client after [_retiredClientGrace] closes both: new requests get the
  /// new client immediately, and in-flight ones get a bounded window to
  /// finish on the old one instead of being killed mid-transfer.
  Future<void> _createHttp11Client() async {
    final previous = _http11Client;
    final replacement = await RhttpCompatibleClient.create(
      settings: ClientSettings(
        httpVersionPref: HttpVersionPref.http1_1,
        timeoutSettings: TimeoutSettings(
          timeout: Duration(seconds: _timeout),
          connectTimeout: Duration(seconds: _connectTimeout),
          keepAliveTimeout: Duration(seconds: _timeout),
          keepAlivePing: const Duration(seconds: 10),
        ),
      ),
    );
    _http11Client = replacement;
    if (previous != null) {
      _retireClient(previous);
    }
  }

  final Set<Timer> _retirementTimers = {};

  void _retireClient(RhttpCompatibleClient client) {
    late final Timer timer;
    timer = Timer(_retiredClientGrace, () {
      _retirementTimers.remove(timer);
      try {
        client.close();
      } catch (_) {
        // Already disposed — nothing to do.
      }
    });
    _retirementTimers.add(timer);
  }

  Future<RhttpCompatibleClient> _getHttp3Client() async {
    _http3Client ??= await RhttpCompatibleClient.create(
      settings: ClientSettings(
        httpVersionPref: HttpVersionPref.http3,
        timeoutSettings: TimeoutSettings(
          timeout: Duration(seconds: _timeout),
          connectTimeout: Duration(seconds: _connectTimeout),
          keepAliveTimeout: Duration(seconds: _timeout),
          keepAlivePing: const Duration(seconds: 10),
        ),
      ),
    );
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
  /// Returns a tuple of (client, protocol version string).
  Future<(RhttpCompatibleClient, String)> _getClientForHost(String host) async {
    switch (_protocolPreference) {
      case NetworkProtocolPreference.http11Only:
        return (_http11Client!, 'HTTP/1.1');

      case NetworkProtocolPreference.http3Only:
        // Try HTTP/3, but fall back if host has failed before
        if (_http3FailedHosts.contains(host)) {
          return (_http11Client!, 'HTTP/1.1 (fallback)');
        }
        return (await _getHttp3Client(), 'HTTP/3');

      case NetworkProtocolPreference.auto:
        // Use HTTP/3 only if we've detected support via alt-svc
        if (_http3SupportedHosts[host] == true &&
            !_http3FailedHosts.contains(host)) {
          return (await _getHttp3Client(), 'HTTP/3');
        }
        return (_http11Client!, 'HTTP/1.1');
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

  /// The shared HTTP/1.1 [RhttpCompatibleClient], for callers that need a
  /// real `http.Client` object rather than this class's static
  /// `get`/`post`/... convenience methods — i.e. anything that hands an
  /// `http.Client` to a third party (`GoogleDriveBackend`, M2.9) or needs
  /// `Client.send()` and a `StreamedResponse`.
  ///
  /// Prefer [sharedClient] over this raw accessor: this one returns the
  /// client object that exists *right now*, and [reloadSettings] closes and
  /// replaces it whenever the user changes a network setting, so a
  /// long-lived holder of this reference would end up using a closed client.
  ///
  /// Throws [StateError] if [init] has not run.
  RhttpCompatibleClient get http11Client {
    final client = _http11Client;
    if (client == null) {
      throw StateError(
        'NetworkProvider HTTP/1.1 client is not available. Call '
        'NetworkProvider.init() first.',
      );
    }
    return client;
  }

  /// A stable, long-lived `http.Client` that routes through this provider's
  /// rhttp stack — the thing to inject into anything that takes an
  /// `http.Client`.
  ///
  /// Why a delegating wrapper rather than the client object itself:
  ///  * [reloadSettings] disposes and recreates `_http11Client`. A consumer
  ///    that captured the old object at wiring time would silently start
  ///    failing after any network-settings change; this wrapper resolves
  ///    the current client per request instead.
  ///  * `close()` is a deliberate no-op. The underlying clients are owned
  ///    by this provider and shared app-wide; a consumer calling `close()`
  ///    on what it reasonably believes is "its" client must not take down
  ///    every other caller's HTTP.
  ///
  /// **What this client does NOT do — read before using it.** Everything in
  /// [_performRequest] is bypassed, because `send()` does not go through it.
  /// Concretely, compared to `NetworkProvider.get/post/put/delete/head`:
  ///
  ///  * **No automatic retries.** [retriableStatusCodes] (408/425/429/500/
  ///    502/503/504) are returned to the caller as ordinary responses, and
  ///    transport exceptions propagate on the first failure. There is no
  ///    exponential backoff. A consumer that wants retries must implement
  ///    them itself.
  ///  * **No HTTP/3.** Always the HTTP/1.1 client: the alt-svc-driven
  ///    upgrade and, more importantly, its fallback-on-failure handling
  ///    also live in [_performRequest]. Handing out a client that could
  ///    silently switch to HTTP/3 with no fallback would turn an unrelated
  ///    transport failure into what looks like an API error.
  ///  * **No alt-svc probing and no AI-console request logging.**
  ///
  /// This is a deliberate division of labour, not an omission: the sole
  /// consumer today, `GoogleDriveBackend`, already owns richer versions of
  /// exactly these concerns — it maps 429/`rateLimitExceeded` to
  /// `SyncRateLimitedException` (carrying Drive's own `Retry-After`), 5xx to
  /// `SyncNetworkException`, and retries 401 once after forcing a token
  /// refresh. A blind retry layer underneath that would replay
  /// non-idempotent Drive creates and fight the backend's own semantics.
  /// **If a future consumer needs generic retry/backoff, it must add it
  /// itself (or wrap this client) — it will not get it from here.**
  static http.Client get sharedClient => _sharedClient ??= _SharedRhttpClient();

  static _SharedRhttpClient? _sharedClient;

  /// Perform a GET request with retry logic.
  static Future<http.Response> get(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    return instance._performRequest('GET', url, () async {
      final (client, _) = await instance._getClientForHost(url.host);
      return client.get(url, headers: headers);
    });
  }

  /// Perform a POST request with retry logic.
  static Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    String? encoding,
  }) async {
    return instance._performRequest('POST', url, () async {
      final (client, _) = await instance._getClientForHost(url.host);
      return client.post(url, headers: headers, body: body);
    });
  }

  /// Perform a PUT request with retry logic.
  static Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    return instance._performRequest('PUT', url, () async {
      final (client, _) = await instance._getClientForHost(url.host);
      return client.put(url, headers: headers, body: body);
    });
  }

  /// Perform a DELETE request with retry logic.
  static Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    return instance._performRequest('DELETE', url, () async {
      final (client, _) = await instance._getClientForHost(url.host);
      return client.delete(url, headers: headers, body: body);
    });
  }

  /// Perform a HEAD request with retry logic.
  static Future<http.Response> head(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    return instance._performRequest('HEAD', url, () async {
      final (client, _) = await instance._getClientForHost(url.host);
      return client.head(url, headers: headers);
    });
  }

  /// Core request execution with retry logic.
  Future<http.Response> _performRequest(
    String method,
    Uri url,
    Future<http.Response> Function() requestFn,
  ) async {
    _lastRequestTime = DateTime.now();
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();

    // Get protocol version for logging
    final (_, protocolVersion) = await _getClientForHost(url.host);

    // Log request start
    LoggerService.logAiConsole(
      consoleOutput: '🌐 $method ${url.host}${url.path} [$protocolVersion]',
      endpoint: url.toString(),
      requestId: requestId,
    );

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
          LoggerService.logAiConsole(
            consoleOutput:
                '🔄 Retry ${attempt + 1}/$_retryCount: $method ${url.host} '
                '(status ${response.statusCode}, waiting ${delay.inMilliseconds}ms)',
            endpoint: url.toString(),
            requestId: requestId,
          );
          LoggerService.warning(
            'Retriable status ${response.statusCode} for ${url.host}, '
            'attempt ${attempt + 1}/$_retryCount, retrying in ${delay.inMilliseconds}ms',
          );
          await Future.delayed(delay);
          attempt++;
          continue;
        }

        // Log success
        final duration = DateTime.now().difference(startTime);
        LoggerService.logAiConsole(
          consoleOutput:
              '✅ $method ${url.host} completed: ${response.statusCode}',
          endpoint: url.toString(),
          requestId: requestId,
          duration: duration,
        );

        return response;
      } on RhttpException catch (e) {
        lastError = e;

        // If HTTP/3 failed, mark host and retry with HTTP/1.1
        if (_protocolPreference != NetworkProtocolPreference.http11Only &&
            !_http3FailedHosts.contains(url.host) &&
            (_http3SupportedHosts[url.host] == true ||
                _protocolPreference == NetworkProtocolPreference.http3Only)) {
          LoggerService.logAiConsole(
            consoleOutput:
                '⚠️ HTTP/3 failed for ${url.host}, falling back to HTTP/1.1',
            endpoint: url.toString(),
            requestId: requestId,
          );
          LoggerService.warning(
            'HTTP/3 failed for ${url.host}, falling back to HTTP/1.1: $e',
          );
          _http3FailedHosts.add(url.host);
          // Retry immediately with HTTP/1.1
          continue;
        }

        if (attempt < _retryCount) {
          final delay = _calculateBackoff(attempt);
          LoggerService.logAiConsole(
            consoleOutput:
                '🔄 Retry ${attempt + 1}/$_retryCount: $method ${url.host} '
                '(error, waiting ${delay.inMilliseconds}ms)',
            endpoint: url.toString(),
            requestId: requestId,
          );
          LoggerService.warning(
            'Request failed for ${url.host}, attempt ${attempt + 1}/$_retryCount, '
            'retrying in ${delay.inMilliseconds}ms: $e',
          );
          await Future.delayed(delay);
          attempt++;
          continue;
        }

        // Log final failure
        final duration = DateTime.now().difference(startTime);
        LoggerService.logAiError(
          error: 'Network request failed: $e',
          endpoint: url.toString(),
          requestId: requestId,
          duration: duration,
        );
        rethrow;
      } catch (e) {
        lastError = e;

        if (attempt < _retryCount) {
          final delay = _calculateBackoff(attempt);
          LoggerService.logAiConsole(
            consoleOutput:
                '🔄 Retry ${attempt + 1}/$_retryCount: $method ${url.host} '
                '(error, waiting ${delay.inMilliseconds}ms)',
            endpoint: url.toString(),
            requestId: requestId,
          );
          LoggerService.warning(
            'Request failed for ${url.host}, attempt ${attempt + 1}/$_retryCount, '
            'retrying in ${delay.inMilliseconds}ms: $e',
          );
          await Future.delayed(delay);
          attempt++;
          continue;
        }

        // Log final failure
        final duration = DateTime.now().difference(startTime);
        LoggerService.logAiError(
          error: 'Network request failed: $e',
          endpoint: url.toString(),
          requestId: requestId,
          duration: duration,
        );
        rethrow;
      }
    }

    // Should not reach here, but just in case
    if (lastResponse != null) {
      return lastResponse;
    }
    final duration = DateTime.now().difference(startTime);
    LoggerService.logAiError(
      error: 'Request failed after $_retryCount retries',
      endpoint: url.toString(),
      requestId: requestId,
      duration: duration,
    );
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
    for (final timer in _instance?._retirementTimers ?? const <Timer>{}) {
      timer.cancel();
    }
    _instance?._retirementTimers.clear();
    _instance?._http11Client?.close();
    _instance?._http3Client?.close();
    _instance = null;
    // Deliberately NOT cleared: `_SharedRhttpClient` holds no state of its
    // own — it resolves `NetworkProvider.instance` per request — so the
    // same wrapper stays valid across an init/dispose/init cycle, and
    // anything that captured it keeps working.
    LoggerService.info('NetworkProvider disposed');
  }
}

/// See [NetworkProvider.sharedClient] for why this indirection exists.
///
/// Streaming note (verified against `RhttpCompatibleClient.send`,
/// `third_party/rhttp/rhttp/lib/src/client/compatible_client.dart`): rhttp's
/// `send` issues `client.requestStream(...)` and returns a real
/// [http.StreamedResponse] whose body is the live response stream, so
/// `http.Response.fromStream(...)` and direct stream consumption both work.
/// It also forces `throwOnStatusCode: false`, so non-2xx responses arrive as
/// responses (which is what `GoogleDriveBackend`'s status-code mapping
/// requires) rather than as thrown exceptions, and wraps every transport
/// error in an [http.ClientException] subclass, which is exactly what
/// `GoogleDriveBackend._send` already catches.
class _SharedRhttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return NetworkProvider.instance.http11Client.send(request);
  }

  /// No-op by design — see [NetworkProvider.sharedClient].
  @override
  void close() {}
}
