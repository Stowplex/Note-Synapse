import 'dart:convert';

/// Typed result of a tool invocation.
///
/// Tool execution crosses several layers that historically each stringified
/// results differently (native tools return `{'error': ...}` maps, MCP
/// returns plain strings, exceptions get `toString()`ed). Downstream logic —
/// retry discipline, honest-failure disclosure, observation formatting —
/// must branch on a typed outcome, never by pattern-matching arbitrary
/// result text.
///
/// Failures cross the string-typed tool boundary as a versioned JSON
/// envelope (`{"error": {...}}`, see [serialize]/[tryParseFailure]); success
/// payloads stay raw so prompt-facing content (skill bodies, note text) is
/// unchanged.
class ToolOutcome {
  /// Stable failure codes. Deterministic argument failures must not be
  /// retried with identical arguments; transport failures may be.
  static const String codeOk = 'ok';
  static const String codeInvalidArgument = 'invalid_argument';
  static const String codeToolError = 'tool_error';
  static const String codeNotFound = 'not_found';
  static const String codeUserDenied = 'user_denied';
  static const String codeTransportError = 'transport_error';

  final bool success;
  final String code;
  final String message;
  final dynamic data;
  final bool retryable;

  const ToolOutcome._({
    required this.success,
    required this.code,
    required this.message,
    this.data,
    required this.retryable,
  });

  const ToolOutcome.success(String payload)
    : this._(success: true, code: codeOk, message: payload, retryable: false);

  const ToolOutcome.failure({
    required String code,
    required String message,
    dynamic data,
    bool retryable = false,
  }) : this._(
         success: false,
         code: code,
         message: message,
         data: data,
         retryable: retryable,
       );

  bool get isUserDenied => code == codeUserDenied;
  bool get isInvalidArgument => code == codeInvalidArgument;

  /// Sentinel marking a failure envelope as harness-produced. Without it, a
  /// tool that legitimately returns an upstream API's error body verbatim
  /// (e.g. a fetch/proxy tool succeeding with '{"error": {...}}' payload)
  /// would be misclassified as a failed call.
  static const String envelopeSentinelKey = 'synapse_tool_outcome';

  /// The string that crosses the tool boundary (and reaches the model).
  String serialize() {
    if (success) return message;
    return jsonEncode({
      envelopeSentinelKey: 1,
      'error': {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
        'retryable': retryable,
      },
    });
  }

  /// Parses a failure envelope produced by [serialize]. Returns null for
  /// anything else — including ordinary result text that merely mentions
  /// errors or error-shaped payloads a tool returned as its successful
  /// output — so classification never depends on free-text matching.
  static ToolOutcome? tryParseFailure(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded[envelopeSentinelKey] != 1) return null;
      final error = decoded['error'];
      if (error is! Map<String, dynamic>) return null;
      final message = error['message'];
      final code = error['code'];
      if (message is! String || code is! String) return null;
      return ToolOutcome.failure(
        code: code,
        message: message,
        data: error['data'],
        retryable: error['retryable'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Normalizes a native tool's raw return value.
  ///
  /// Native tools conventionally return `{'error': ...}` maps on failure
  /// (optionally with a `'code'`) and either strings or result maps on
  /// success. Success maps are JSON-encoded — Dart's `Map.toString()` is not
  /// JSON and teaches the model malformed syntax.
  static ToolOutcome fromNativeResult(String toolName, dynamic result) {
    if (result is Map) {
      final error = result['error'];
      if (error != null) {
        final code = result['code'];
        return ToolOutcome.failure(
          code: code is String ? code : codeToolError,
          message: error.toString(),
        );
      }
      try {
        return ToolOutcome.success(jsonEncode(result));
      } catch (_) {
        return ToolOutcome.success(result.toString());
      }
    }
    return ToolOutcome.success(result?.toString() ?? '');
  }

  /// Normalizes a user-defined AI tool's string result. These tools return
  /// JSON text and signal failure with `"success": false`.
  static ToolOutcome fromAiToolResult(String toolName, String result) {
    final envelope = tryParseFailure(result);
    if (envelope != null) return envelope;
    final trimmed = result.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map && decoded['success'] == false) {
          return ToolOutcome.failure(
            code: codeToolError,
            message: result,
          );
        }
      } catch (_) {
        // Not JSON — treat as plain success text.
      }
    }
    return ToolOutcome.success(result);
  }

  static ToolOutcome fromException(String toolName, Object error) {
    return ToolOutcome.failure(
      code: codeToolError,
      message: 'Error executing $toolName: $error',
    );
  }
}

/// Canonical identity of a tool call for retry-discipline bookkeeping.
/// Key order inside [params] does not change the key, so a model that merely
/// reorders JSON keys between retries still hits the same entry.
String canonicalToolCallKey({
  required String serviceName,
  required String toolName,
  required Map<String, dynamic> params,
}) {
  return jsonEncode({
    'service': serviceName,
    'tool': toolName,
    'params': _canonicalize(params),
  });
}

dynamic _canonicalize(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonicalize(value[key])};
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}
