/// Utilities for handling <think></think> tags from OpenAI-compatible models.
///
/// Some models (e.g., Minimax-M2) output reasoning in <think> tags interleaved
/// with their responses. These utilities strip the tags for parsing while
/// preserving the content for multi-turn conversation enhancement.

/// Result of stripping think tags from a response.
class ThinkTagResult {
  /// The content with all <think>...</think> blocks removed.
  final String cleanedContent;

  /// The extracted think content (concatenated if multiple blocks).
  /// Null if no think tags were found.
  final String? thinkContent;

  const ThinkTagResult({required this.cleanedContent, this.thinkContent});
}

/// Pattern to match <think>...</think> blocks (case-insensitive, dotAll for multiline).
final _thinkTagPattern = RegExp(
  r'<think>(.*?)</think>',
  caseSensitive: false,
  dotAll: true,
);

/// Strips all <think>...</think> tags from the input.
///
/// Returns a [ThinkTagResult] containing:
/// - [cleanedContent]: The input with all think blocks removed
/// - [thinkContent]: The concatenated content of all think blocks (null if none)
///
/// Example:
/// ```dart
/// final input = '<think>reasoning</think>[{"name": "task"}]';
/// final result = stripThinkTags(input);
/// print(result.cleanedContent); // '[{"name": "task"}]'
/// print(result.thinkContent);   // 'reasoning'
/// ```
ThinkTagResult stripThinkTags(String input) {
  final matches = _thinkTagPattern.allMatches(input);

  if (matches.isEmpty) {
    return ThinkTagResult(cleanedContent: input);
  }

  // Extract all think content
  final thinkParts = <String>[];
  for (final match in matches) {
    final content = match.group(1)?.trim();
    if (content != null && content.isNotEmpty) {
      thinkParts.add(content);
    }
  }

  // Remove all think tags from input
  final cleanedContent = input.replaceAll(_thinkTagPattern, '').trim();

  return ThinkTagResult(
    cleanedContent: cleanedContent,
    thinkContent: thinkParts.isNotEmpty ? thinkParts.join('\n\n') : null,
  );
}

/// Extracts JSON from a response that may contain think tags and other text.
///
/// This provides robust JSON extraction by:
/// 1. Stripping think tags first
/// 2. Looking for JSON in ```json...``` code blocks (preferred)
/// 3. Falling back to finding raw JSON arrays [...] or objects {...}
///
/// Returns null if no valid JSON structure is found.
///
/// The [expectArray] parameter hints whether to prioritize array ([...]) or
/// object ({...}) extraction when no code block is found.
String? extractJsonFromResponse(String response, {bool expectArray = false}) {
  // Step 1: Strip think tags
  final stripped = stripThinkTags(response);
  final content = stripped.cleanedContent;

  // Step 2: Look for ```json...``` code block (most reliable)
  final jsonBlockMatch = RegExp(
    r'```json\s*([\s\S]*?)\s*```',
    caseSensitive: false,
  ).firstMatch(content);

  if (jsonBlockMatch != null) {
    return jsonBlockMatch.group(1)?.trim();
  }

  // Step 3: Look for raw JSON structure
  if (expectArray) {
    // Find the outermost array
    final arrayMatch = RegExp(r'\[[\s\S]*\]').firstMatch(content);
    if (arrayMatch != null) {
      return _extractBalancedJson(content, arrayMatch.start, '[', ']');
    }
  } else {
    // Find the outermost object
    final objectMatch = RegExp(r'\{[\s\S]*\}').firstMatch(content);
    if (objectMatch != null) {
      return _extractBalancedJson(content, objectMatch.start, '{', '}');
    }
  }

  // Step 4: Try the opposite structure type as fallback
  if (expectArray) {
    final objectMatch = RegExp(r'\{[\s\S]*\}').firstMatch(content);
    if (objectMatch != null) {
      return _extractBalancedJson(content, objectMatch.start, '{', '}');
    }
  } else {
    final arrayMatch = RegExp(r'\[[\s\S]*\]').firstMatch(content);
    if (arrayMatch != null) {
      return _extractBalancedJson(content, arrayMatch.start, '[', ']');
    }
  }

  return null;
}

/// Extracts a balanced JSON structure starting from [startIdx].
///
/// Uses bracket counting to find the matching closing bracket.
String? _extractBalancedJson(
  String content,
  int startIdx,
  String openChar,
  String closeChar,
) {
  int depth = 0;
  bool inString = false;
  bool escapeNext = false;

  for (int i = startIdx; i < content.length; i++) {
    final char = content[i];

    if (escapeNext) {
      escapeNext = false;
      continue;
    }

    if (char == '\\' && inString) {
      escapeNext = true;
      continue;
    }

    if (char == '"') {
      inString = !inString;
      continue;
    }

    if (!inString) {
      if (char == openChar) {
        depth++;
      } else if (char == closeChar) {
        depth--;
        if (depth == 0) {
          return content.substring(startIdx, i + 1);
        }
      }
    }
  }

  return null; // Unbalanced
}

/// Formats think content for prepending to assistant message in conversation history.
///
/// This wraps the think content in <think></think> tags so models that expect
/// this format can benefit from the reasoning context.
String formatThinkForHistory(String thinkContent) {
  return '<think>$thinkContent</think>';
}

/// Checks if a JSON map contains a valid agent action key.
///
/// Valid keys are: 'answer', 'tool', 'think', 'spawn_subtasks'.
bool isAgentAction(Map<String, dynamic> json) {
  return json.containsKey('answer') ||
      json.containsKey('tool') ||
      json.containsKey('think') ||
      json.containsKey('spawn_subtasks');
}
