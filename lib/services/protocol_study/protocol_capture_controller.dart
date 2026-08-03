import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../models/protocol_exchange.dart';
import '../../models/protocol_study.dart';

/// Accepts untrusted messages from a page-world JavaScript probe and assembles
/// them into bounded, typed exchanges.
///
/// This controller intentionally remains owned by the Protocol Study route. It
/// is not registered in GetIt, so arbitrary services cannot enumerate the raw
/// workspace through the app-wide service locator.
class ProtocolCaptureController extends ChangeNotifier {
  ProtocolCaptureController({
    this.limits = const ProtocolCaptureLimits(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  factory ProtocolCaptureController.fromExchanges({
    required Iterable<ProtocolExchange> exchanges,
    ProtocolCaptureLimits limits = const ProtocolCaptureLimits(),
  }) {
    final controller = ProtocolCaptureController(limits: limits);
    controller._exchanges.addAll(exchanges);
    for (final exchange in controller._exchanges) {
      if (exchange.exampleIndex > controller._currentExampleIndex) {
        controller._currentExampleIndex = exchange.exampleIndex;
      }
    }
    return controller;
  }

  final ProtocolCaptureLimits limits;
  final DateTime Function() _now;
  final List<ProtocolExchange> _exchanges = [];
  final List<ProtocolInteraction> _interactions = [];
  final List<String> _issues = [];
  final Map<String, _BodyAccumulator> _bodyAccumulators = {};
  final Queue<DateTime> _recentEvents = Queue<DateTime>();

  int _acceptedEventCount = 0;
  int _acceptedBytes = 0;
  bool _stoppedByLimit = false;
  bool _disposed = false;
  String? _pageInstanceId;
  Map<String, bool> _capabilities = const {};
  int _currentExampleIndex = 1;

  UnmodifiableListView<ProtocolExchange> get exchanges =>
      UnmodifiableListView(_exchanges);
  UnmodifiableListView<ProtocolInteraction> get interactions =>
      UnmodifiableListView(_interactions);
  UnmodifiableListView<String> get issues => UnmodifiableListView(_issues);
  int get acceptedEventCount => _acceptedEventCount;
  int get acceptedBytes => _acceptedBytes;
  bool get stoppedByLimit => _stoppedByLimit;
  String? get pageInstanceId => _pageInstanceId;
  Map<String, bool> get capabilities => UnmodifiableMapView(_capabilities);
  int get currentExampleIndex => _currentExampleIndex;

  /// Returns true only when [raw] passes schema, rate, and size checks.
  bool acceptEvent(dynamic raw) {
    if (_disposed || _stoppedByLimit || raw is! Map) {
      return false;
    }
    final event = Map<String, dynamic>.from(raw);
    Uint8List encoded;
    try {
      encoded = utf8.encode(jsonEncode(event));
    } catch (_) {
      _recordIssue('Rejected a non-JSON capture event.');
      return false;
    }
    if (encoded.length > limits.maxEventBytes) {
      _recordIssue('Rejected an oversized capture event.');
      return false;
    }
    if (_acceptedEventCount >= limits.maxEvents ||
        _acceptedBytes + encoded.length > limits.maxSessionBytes) {
      _stoppedByLimit = true;
      _recordIssue('Capture stopped at the configured session limit.');
      notifyListeners();
      return false;
    }
    final now = _now();
    while (_recentEvents.isNotEmpty &&
        now.difference(_recentEvents.first) >= const Duration(seconds: 1)) {
      _recentEvents.removeFirst();
    }
    if (_recentEvents.length >= limits.maxEventsPerSecond) {
      _recordIssue('Dropped capture events that exceeded the rate limit.');
      return false;
    }

    final type = event['type'];
    final pageId = event['pageInstanceId'];
    final sequence = event['sequence'];
    if (event['schemaVersion'] != 1 ||
        type is! String ||
        !_knownTypes.contains(type) ||
        pageId is! String ||
        !_safeIdentifier(pageId) ||
        sequence is! num ||
        sequence.toInt() <= 0) {
      _recordIssue('Rejected a capture event with an invalid schema.');
      return false;
    }

    _recentEvents.addLast(now);
    _acceptedEventCount += 1;
    _acceptedBytes += encoded.length;
    _pageInstanceId ??= pageId;

    try {
      _apply(type, event, now);
    } catch (_) {
      _recordIssue('Rejected malformed data in a capture event.');
      return false;
    }
    notifyListeners();
    return true;
  }

  void setSelected(String exchangeId, bool selected) {
    final index = _indexOf(exchangeId);
    if (index < 0) return;
    _exchanges[index] = _exchanges[index].copyWith(selected: selected);
    notifyListeners();
  }

  /// Marks subsequent traffic as another example of the workflow. Existing
  /// traffic remains untouched so the AI can compare value changes across
  /// runs without any keystroke recording.
  void startNewExample() {
    if (_disposed) return;
    _currentExampleIndex += 1;
    _interactions.add(
      ProtocolInteraction(
        kind: 'example_marker',
        timestamp: _now(),
        label: 'Example $_currentExampleIndex',
      ),
    );
    notifyListeners();
  }

  void setParameter(String fieldId, bool isParameter) {
    if (_disposed) return;
    var changed = false;
    List<ProtocolField> updateFields(List<ProtocolField> fields) => fields
        .map((field) {
          if (field.id != fieldId || field.isParameter == isParameter) {
            return field;
          }
          changed = true;
          return field.copyWith(isParameter: isParameter);
        })
        .toList(growable: false);

    for (var index = 0; index < _exchanges.length; index++) {
      final exchange = _exchanges[index];
      final requestBody = exchange.requestBody;
      final responseBody = exchange.responseBody;
      final parameterFieldIds = {...exchange.parameterFieldIds};
      if (fieldId.startsWith('${exchange.id}:')) {
        if (isParameter) {
          changed = parameterFieldIds.add(fieldId) || changed;
        } else {
          changed = parameterFieldIds.remove(fieldId) || changed;
        }
      }
      final updated = exchange.copyWith(
        requestHeaders: updateFields(exchange.requestHeaders),
        queryFields: updateFields(exchange.queryFields),
        requestBody: requestBody?.copyWith(
          fields: updateFields(requestBody.fields),
        ),
        responseHeaders: updateFields(exchange.responseHeaders),
        responseBody: responseBody?.copyWith(
          fields: updateFields(responseBody.fields),
        ),
        parameterFieldIds: Set.unmodifiable(parameterFieldIds),
      );
      _exchanges[index] = updated;
    }
    if (changed) notifyListeners();
  }

  /// Adds a header observed by trusted native/Dart code rather than by the
  /// untrusted page bridge. Used for browser-managed cookie state, which page
  /// JavaScript cannot see (especially HttpOnly cookies).
  void addTrustedHeader(
    String exchangeId, {
    required bool request,
    required String name,
    required String value,
  }) {
    if (_disposed || value.isEmpty) return;
    final index = _indexOf(exchangeId);
    if (index < 0) return;
    final exchange = _exchanges[index];
    final location = request
        ? ProtocolFieldLocation.requestHeader
        : ProtocolFieldLocation.responseHeader;
    final current = request
        ? exchange.requestHeaders
        : exchange.responseHeaders;
    final withoutPrior = current
        .where((field) => field.name.toLowerCase() != name.toLowerCase())
        .toList();
    withoutPrior.add(
      ProtocolField(
        id: '$exchangeId:${location.name}:trusted:${name.toLowerCase()}',
        location: location,
        name: name,
        value: _bounded(value, 64 * 1024) ?? '<oversized>',
      ),
    );
    _exchanges[index] = request
        ? exchange.copyWith(requestHeaders: List.unmodifiable(withoutPrior))
        : exchange.copyWith(responseHeaders: List.unmodifiable(withoutPrior));
    notifyListeners();
  }

  void clear() {
    _exchanges.clear();
    _interactions.clear();
    _issues.clear();
    _bodyAccumulators.clear();
    _recentEvents.clear();
    _acceptedEventCount = 0;
    _acceptedBytes = 0;
    _stoppedByLimit = false;
    _pageInstanceId = null;
    _capabilities = const {};
    _currentExampleIndex = 1;
    notifyListeners();
  }

  void _apply(String type, Map<String, dynamic> event, DateTime receivedAt) {
    switch (type) {
      case 'hello':
        final rawCapabilities = event['capabilities'];
        if (rawCapabilities is Map) {
          final merged = {..._capabilities};
          for (final entry in rawCapabilities.entries) {
            if (entry.key is! String || entry.value is! bool) continue;
            final prior = merged[entry.key];
            // A later iframe/navigation cannot erase a limitation already
            // observed elsewhere in the one-tab study.
            merged[entry.key as String] = prior == false
                ? false
                : entry.value as bool;
          }
          _capabilities = Map.unmodifiable(merged);
        }
      case 'diagnostic':
        final code = _bounded(event['code'], 80) ?? 'probe_diagnostic';
        if (code == 'wrapper_replaced') {
          _capabilities = {..._capabilities, 'wrapperIntegrity': false};
        }
        _recordIssue('Protocol capture diagnostic: $code.');
      case 'request':
        _acceptRequest(event, receivedAt);
      case 'requestBody':
        _acceptWholeBody(event, request: true);
      case 'response':
        _acceptResponse(event);
      case 'responseBody':
        _acceptWholeBody(event, request: false);
      case 'requestBodyStart':
      case 'responseBodyStart':
        _startBody(event, request: type.startsWith('request'));
      case 'requestBodyChunk':
      case 'responseBodyChunk':
        _appendBody(event, request: type.startsWith('request'));
      case 'requestBodyEnd':
      case 'responseBodyEnd':
        _finishBody(event, request: type.startsWith('request'));
      case 'complete':
        _complete(event, receivedAt);
      case 'error':
        _complete(event, receivedAt, error: _bounded(event['error'], 4096));
      case 'interaction':
        _interactions.add(
          ProtocolInteraction(
            kind: _bounded(event['kind'], 40) ?? 'interaction',
            timestamp: _eventTime(event, receivedAt),
            label: _bounded(event['label'], 240),
            selectorHint: _bounded(event['selectorHint'], 240),
          ),
        );
      case 'form':
        _acceptForm(event, receivedAt);
    }
  }

  void _acceptRequest(Map<String, dynamic> event, DateTime receivedAt) {
    final id = _exchangeId(event);
    if (_indexOf(id) >= 0) return;
    final documentUrl = _bounded(event['documentUrl'], 64 * 1024);
    final rawUrl = _bounded(event['url'], 64 * 1024) ?? '';
    final url = _resolveUrl(rawUrl, documentUrl);
    final uri = Uri.tryParse(url);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException('unsupported request URL');
    }
    final method = (_bounded(event['method'], 20) ?? 'GET').toUpperCase();
    final sourceName = _bounded(event['source'], 20) ?? 'unknown';
    final source = ProtocolRequestSource.values
        .where((value) => value.name == sourceName)
        .firstOrNull;
    _exchanges.add(
      ProtocolExchange(
        id: id,
        pageInstanceId: event['pageInstanceId'] as String,
        sequence: (event['sequence'] as num).toInt(),
        source: source ?? ProtocolRequestSource.unknown,
        method: method,
        url: url,
        startedAt: _eventTime(event, receivedAt),
        requestHeaders: _fieldsFromPairs(
          event['headers'],
          id,
          ProtocolFieldLocation.requestHeader,
        ),
        queryFields: _queryFields(uri, id),
        responseHeaders: const [],
        requestMetadata: _requestMetadata(event['metadata']),
        exampleIndex: _currentExampleIndex,
        mutatesState: !const {'GET', 'HEAD', 'OPTIONS'}.contains(method),
      ),
    );
  }

  void _acceptResponse(Map<String, dynamic> event) {
    final id = _exchangeId(event);
    final index = _indexOf(id);
    if (index < 0) return;
    final exchange = _exchanges[index];
    final status = event['status'] is num
        ? (event['status'] as num).toInt().clamp(0, 999)
        : null;
    final rawResponseUrl = _bounded(event['url'], 64 * 1024);
    final resolvedResponseUrl = rawResponseUrl == null
        ? null
        : _resolveUrl(rawResponseUrl, exchange.url);
    final parsedResponseUrl = resolvedResponseUrl == null
        ? null
        : Uri.tryParse(resolvedResponseUrl);
    final responseUrl =
        parsedResponseUrl != null &&
            const {'http', 'https'}.contains(parsedResponseUrl.scheme)
        ? resolvedResponseUrl
        : null;
    final redirected = event['redirected'] is bool
        ? event['redirected'] as bool
        : responseUrl != null && responseUrl != exchange.url;
    final responseType = _bounded(event['responseType'], 40);
    final captureIssues =
        const {'opaque', 'opaqueredirect'}.contains(responseType)
        ? List<String>.unmodifiable({
            ...exchange.captureIssues,
            'opaque_response_body_unavailable',
          })
        : exchange.captureIssues;
    _exchanges[index] = _exchanges[index].copyWith(
      status: status,
      responseUrl: responseUrl,
      redirected: redirected,
      responseHeaders: _fieldsFromPairs(
        event['headers'],
        id,
        ProtocolFieldLocation.responseHeader,
      ),
      captureIssues: captureIssues,
    );
  }

  void _acceptWholeBody(Map<String, dynamic> event, {required bool request}) {
    final id = _exchangeId(event);
    final body = _bodyFrom(event['body'], id, request: request);
    _setBody(id, body, request: request);
  }

  void _startBody(Map<String, dynamic> event, {required bool request}) {
    final id = _exchangeId(event);
    if (_indexOf(id) < 0) return;
    final rawBody = event['body'];
    final meta = rawBody is Map
        ? Map<String, dynamic>.from(rawBody)
        : <String, dynamic>{};
    _bodyAccumulators[_bodyKey(id, request)] = _BodyAccumulator(meta);
  }

  void _appendBody(Map<String, dynamic> event, {required bool request}) {
    final id = _exchangeId(event);
    final accumulator = _bodyAccumulators[_bodyKey(id, request)];
    final text = event['text'];
    if (accumulator == null || text is! String) return;
    final maximum = request
        ? limits.maxRequestBodyBytes
        : limits.maxResponseBodyBytes;
    accumulator.append(text, maximum);
  }

  void _finishBody(Map<String, dynamic> event, {required bool request}) {
    final id = _exchangeId(event);
    final accumulator = _bodyAccumulators.remove(_bodyKey(id, request));
    if (accumulator == null) return;
    final data = <String, dynamic>{
      ...accumulator.meta,
      'text': accumulator.text,
    };
    if (accumulator.truncated) data['truncated'] = true;
    _setBody(id, _bodyFrom(data, id, request: request), request: request);
  }

  void _setBody(String id, ProtocolBody body, {required bool request}) {
    final index = _indexOf(id);
    if (index < 0) return;
    _exchanges[index] = request
        ? _exchanges[index].copyWith(requestBody: body)
        : _exchanges[index].copyWith(responseBody: body);
  }

  void _complete(
    Map<String, dynamic> event,
    DateTime receivedAt, {
    String? error,
  }) {
    final id = _exchangeId(event);
    final index = _indexOf(id);
    if (index < 0) return;
    final omittedReason = _bounded(event['omittedReason'], 512);
    final captureIssues = omittedReason == null
        ? _exchanges[index].captureIssues
        : List<String>.unmodifiable({
            ..._exchanges[index].captureIssues,
            omittedReason,
          });
    _exchanges[index] = _exchanges[index].copyWith(
      completedAt: _eventTime(event, receivedAt),
      error: error,
      captureIssues: captureIssues,
    );
  }

  void _acceptForm(Map<String, dynamic> event, DateTime receivedAt) {
    final pageId = event['pageInstanceId'] as String;
    final id = '$pageId:form:${(event['sequence'] as num).toInt()}';
    final documentUrl = _bounded(event['documentUrl'], 64 * 1024);
    final action = _resolveUrl(
      _bounded(event['action'], 64 * 1024) ?? '',
      documentUrl,
    );
    final uri = Uri.tryParse(action);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) return;
    final method = (_bounded(event['method'], 20) ?? 'GET').toUpperCase();
    final fields = _fieldsFromPairs(
      event['fields'],
      id,
      ProtocolFieldLocation.requestBody,
    );
    final bodyText = jsonEncode([
      for (final field in fields) [field.name, field.value],
    ]);
    _exchanges.add(
      ProtocolExchange(
        id: id,
        pageInstanceId: pageId,
        sequence: (event['sequence'] as num).toInt(),
        source: ProtocolRequestSource.form,
        method: method,
        url: action,
        startedAt: _eventTime(event, receivedAt),
        completedAt: _eventTime(event, receivedAt),
        requestHeaders: const [],
        queryFields: _queryFields(uri, id),
        requestBody: ProtocolBody(
          text: bodyText,
          mimeType: 'application/x-note-synapse-form-fields+json',
          byteLength: utf8.encode(bodyText).length,
          fields: fields,
        ),
        responseHeaders: const [],
        mutatesState: !const {'GET', 'HEAD', 'OPTIONS'}.contains(method),
        exampleIndex: _currentExampleIndex,
      ),
    );
    _interactions.add(
      ProtocolInteraction(
        kind: 'form_submit',
        timestamp: _eventTime(event, receivedAt),
        selectorHint: _bounded(event['selectorHint'], 240),
      ),
    );
  }

  ProtocolBody _bodyFrom(
    dynamic raw,
    String exchangeId, {
    required bool request,
  }) {
    if (raw is! Map) return const ProtocolBody(omittedReason: 'not_captured');
    final data = Map<String, dynamic>.from(raw);
    final maximum = request
        ? limits.maxRequestBodyBytes
        : limits.maxResponseBodyBytes;
    final rawText = data['text'];
    String? text;
    var truncated = data['truncated'] as bool? ?? false;
    int? byteLength = (data['byteLength'] as num?)?.toInt();
    if (rawText is String) {
      final capped = _capUtf8(rawText, maximum);
      text = capped.text;
      byteLength ??= capped.originalBytes;
      truncated = truncated || capped.truncated;
    }
    final mimeType = _bounded(data['mimeType'], 512);
    return ProtocolBody(
      text: text,
      mimeType: mimeType,
      byteLength: byteLength,
      truncated: truncated,
      omittedReason: _bounded(data['omittedReason'], 512),
      fields: text == null
          ? const []
          : _deriveBodyFields(text, mimeType, exchangeId, request: request),
    );
  }

  List<ProtocolField> _deriveBodyFields(
    String text,
    String? mimeType,
    String exchangeId, {
    required bool request,
  }) {
    final location = request
        ? ProtocolFieldLocation.requestBody
        : ProtocolFieldLocation.responseBody;
    final result = <ProtocolField>[];
    void add(String name, Object? value) {
      if (result.length >= 256) return;
      result.add(
        ProtocolField(
          id: '$exchangeId:${location.name}:${result.length}',
          location: location,
          name: name,
          value: _bounded(value, 64 * 1024) ?? '',
        ),
      );
    }

    try {
      if (mimeType?.contains('json') == true ||
          text.trimLeft().startsWith('{') ||
          text.trimLeft().startsWith('[')) {
        void visit(Object? value, String path, int depth) {
          if (depth > 8 || result.length >= 256) return;
          if (value is Map) {
            for (final entry in value.entries) {
              visit(
                entry.value,
                path.isEmpty ? '${entry.key}' : '$path.${entry.key}',
                depth + 1,
              );
            }
          } else if (value is List) {
            for (var i = 0; i < value.length && i < 50; i++) {
              visit(value[i], '$path[$i]', depth + 1);
            }
          } else {
            add(path.isEmpty ? r'$' : path, value);
          }
        }

        visit(jsonDecode(text), '', 0);
      } else if (mimeType?.contains('x-www-form-urlencoded') == true ||
          (text.contains('=') && !text.contains('\n'))) {
        final values = Uri.splitQueryString(text);
        values.forEach(add);
      }
    } catch (_) {
      // The raw text remains locally visible even when structured parsing is
      // not possible. It is never silently substituted into an AI projection.
    }
    return result;
  }

  List<ProtocolField> _fieldsFromPairs(
    dynamic raw,
    String exchangeId,
    ProtocolFieldLocation location,
  ) {
    if (raw is! List) return const [];
    final result = <ProtocolField>[];
    for (final pair in raw.take(512)) {
      if (pair is! List || pair.length < 2) continue;
      final name = _bounded(pair[0], 512);
      final value = pair[1] is String
          ? _bounded(pair[1], 64 * 1024)
          : _bounded(jsonEncode(pair[1]), 64 * 1024);
      if (name == null || value == null) continue;
      result.add(
        ProtocolField(
          id: '$exchangeId:${location.name}:${result.length}',
          location: location,
          name: name,
          value: value,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  List<ProtocolField> _queryFields(Uri uri, String exchangeId) {
    final result = <ProtocolField>[];
    for (final entry in uri.queryParametersAll.entries) {
      for (final value in entry.value) {
        result.add(
          ProtocolField(
            id: '$exchangeId:${ProtocolFieldLocation.query.name}:${result.length}',
            location: ProtocolFieldLocation.query,
            name: entry.key,
            value: value,
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  Map<String, String> _requestMetadata(dynamic raw) {
    if (raw is! Map) return const {};
    const allowed = {
      'cache',
      'capture',
      'credentials',
      'destination',
      'integrity',
      'keepalive',
      'mode',
      'redirect',
      'referrer',
      'referrerPolicy',
      'responseType',
      'synchronous',
      'withCredentials',
    };
    final result = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || !allowed.contains(entry.key)) continue;
      final value = _bounded(entry.value, 2048);
      if (value != null) result[entry.key as String] = value;
    }
    return Map.unmodifiable(result);
  }

  DateTime _eventTime(Map<String, dynamic> event, DateTime fallback) {
    final milliseconds = event['timestampMs'];
    if (milliseconds is! num) return fallback;
    final parsed = DateTime.fromMillisecondsSinceEpoch(
      milliseconds.toInt(),
      isUtc: true,
    );
    if (parsed.difference(fallback).abs() > const Duration(days: 1)) {
      return fallback;
    }
    return parsed;
  }

  String _exchangeId(Map<String, dynamic> event) {
    final id = event['exchangeId'];
    if (id is! String || !_safeIdentifier(id)) {
      throw const FormatException('invalid exchange ID');
    }
    return id;
  }

  int _indexOf(String id) => _exchanges.indexWhere((item) => item.id == id);

  String _resolveUrl(String value, String? documentUrl) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return uri.toString();
    final base = Uri.tryParse(documentUrl ?? '');
    return base?.resolve(value).toString() ?? value;
  }

  String? _bounded(dynamic value, int maximum) {
    if (value == null) return null;
    final text = value is String ? value : value.toString();
    if (text.length > limits.maxStringLength) return null;
    return text.length <= maximum ? text : text.substring(0, maximum);
  }

  _CappedText _capUtf8(String value, int maximum) {
    final encoded = utf8.encode(value);
    if (encoded.length <= maximum) {
      return _CappedText(value, encoded.length, false);
    }
    return _CappedText(
      utf8.decode(encoded.sublist(0, maximum), allowMalformed: true),
      encoded.length,
      true,
    );
  }

  void _recordIssue(String issue) {
    if (_issues.isEmpty || _issues.last != issue) {
      if (_issues.length >= 50) _issues.removeAt(0);
      _issues.add(issue);
    }
  }

  static String _bodyKey(String id, bool request) =>
      '${request ? 'request' : 'response'}:$id';

  static bool _safeIdentifier(String value) =>
      value.isNotEmpty &&
      value.length <= 240 &&
      RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value);

  static const Set<String> _knownTypes = {
    'hello',
    'request',
    'requestBody',
    'requestBodyStart',
    'requestBodyChunk',
    'requestBodyEnd',
    'response',
    'responseBody',
    'responseBodyStart',
    'responseBodyChunk',
    'responseBodyEnd',
    'complete',
    'error',
    'form',
    'interaction',
    'diagnostic',
  };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _BodyAccumulator {
  _BodyAccumulator(this.meta);

  final Map<String, dynamic> meta;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  bool truncated = false;

  void append(String text, int maximum) {
    if (truncated) return;
    final incoming = utf8.encode(text);
    final remaining = maximum - _bytes.length;
    if (remaining <= 0) {
      truncated = true;
      return;
    }
    if (incoming.length <= remaining) {
      _bytes.add(incoming);
    } else {
      _bytes.add(incoming.sublist(0, remaining));
      truncated = true;
    }
  }

  String get text => utf8.decode(_bytes.takeBytes(), allowMalformed: true);
}

class _CappedText {
  const _CappedText(this.text, this.originalBytes, this.truncated);

  final String text;
  final int originalBytes;
  final bool truncated;
}
