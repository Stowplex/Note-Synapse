import 'dart:convert';

import 'model_response.dart';

/// Shared JSON parsing helpers used by the JSON and Qwen format parsers.
/// Ported from flutter_gemma's JsonParsingUtils; debug-print noise dropped
/// (callers use LoggerService instead).
class JsonParsingUtils {
  /// Strip Gemma-style `<start_of_turn>model ... <end_of_turn>` wrappers so
  /// downstream parsers can focus on content.
  static String cleanModelResponse(String response) {
    final turnRegex = RegExp(r'<start_of_turn>model\s*([\s\S]*?)<end_of_turn>');
    final match = turnRegex.firstMatch(response);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return response.replaceAll(RegExp(r'<end_of_turn>\s*$'), '').trim();
  }

  /// Parse a JSON string into a [FunctionCallResponse].
  /// Accepts arg key names `parameters`, `args`, or `arguments`.
  static FunctionCallResponse? parseJsonString(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) return null;
      final name = decoded['name'] as String?;
      if (name == null) return null;
      final args = (decoded['parameters'] as Map<String, dynamic>?) ??
          (decoded['args'] as Map<String, dynamic>?) ??
          (decoded['arguments'] as Map<String, dynamic>?);
      return FunctionCallResponse(
        name: name,
        args: args ?? <String, dynamic>{},
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse a JSON array of call objects; returns all successful parses.
  static List<FunctionCallResponse> parseJsonArray(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        final results = <FunctionCallResponse>[];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final result = parseJsonString(jsonEncode(item));
            if (result != null) results.add(result);
          }
        }
        return results;
      }
    } catch (_) {}
    return [];
  }

  /// Split text that contains multiple JSON objects (newline / comma
  /// separated, or a top-level array) and parse each.
  static List<FunctionCallResponse> parseMultipleJsonObjects(String text) {
    final results = <FunctionCallResponse>[];
    final trimmed = text.trim();

    if (trimmed.startsWith('[')) {
      final arrayResults = parseJsonArray(trimmed);
      if (arrayResults.isNotEmpty) return arrayResults;
    }

    // Brace-tracking split of top-level objects.
    int braceCount = 0;
    bool inString = false;
    bool escaped = false;
    int objectStart = -1;

    for (int i = 0; i < trimmed.length; i++) {
      final char = trimmed[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == '\\') {
        escaped = true;
        continue;
      }
      if (char == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (char == '{') {
        if (braceCount == 0) objectStart = i;
        braceCount++;
      } else if (char == '}') {
        braceCount--;
        if (braceCount == 0 && objectStart >= 0) {
          final jsonStr = trimmed.substring(objectStart, i + 1);
          final result = parseJsonString(jsonStr);
          if (result != null) results.add(result);
          objectStart = -1;
        }
      }
    }
    return results;
  }

  /// Fast brace-balance check — useful for streaming completion detection.
  static bool isBalancedJson(String str) {
    int braceCount = 0;
    bool inString = false;
    bool escaped = false;
    bool hasSeenOpenBrace = false;

    for (int i = 0; i < str.length; i++) {
      final char = str[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == '\\') {
        escaped = true;
        continue;
      }
      if (char == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (char == '{') {
        braceCount++;
        hasSeenOpenBrace = true;
      } else if (char == '}') {
        braceCount--;
        if (braceCount < 0) return false;
      }
    }
    return braceCount == 0 && hasSeenOpenBrace;
  }

  /// Early-exit heuristic: is this buffer definitely text (no tool markers
  /// in the first 30 characters)? Callers may add model-specific indicators.
  static bool isDefinitelyText(
    String buffer, {
    List<String> extraIndicators = const [],
  }) {
    final clean = buffer.trim();
    if (clean.length < 5) return false;

    final early = clean.length > 30 ? clean.substring(0, 30) : clean;
    if (early.contains('{') ||
        early.toLowerCase().contains('json') ||
        early.contains('<tool')) {
      return false;
    }
    for (final indicator in extraIndicators) {
      if (early.contains(indicator)) return false;
    }
    return true;
  }
}
