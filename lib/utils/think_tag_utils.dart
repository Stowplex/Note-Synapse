/// Utilities for handling <think></think> tags from OpenAI-compatible models.
///
/// Some models (e.g., Minimax-M2) output reasoning in <think> tags interleaved
/// with their responses. These utilities strip the tags for parsing while
/// preserving the content for multi-turn conversation enhancement.
import 'dart:convert';

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
    // Find the outermost array (keep existing logic for arrays for now, or improve if needed)
    final arrayMatch = RegExp(r'\[[\s\S]*\]').firstMatch(content);
    if (arrayMatch != null) {
      return _extractBalancedJson(content, arrayMatch.start, '[', ']');
    }
  } else {
    // Find all potential JSON objects
    final candidates = <String>[];
    int start = 0;

    // Scan for all top-level balanced braces
    while (start < content.length) {
      final match = RegExp(r'\{').firstMatch(content.substring(start));
      if (match == null) break;

      final realStart = start + match.start;
      final json = _extractBalancedJson(content, realStart, '{', '}');

      if (json != null) {
        candidates.add(json);
        // Move start past this object to find the next one
        start = realStart + json.length;
      } else {
        // Unbalanced or failed, move forward one char
        start = realStart + 1;
      }
    }

    if (candidates.isEmpty) return null;

    // Filter and score candidates to find the "best" agent action
    String? bestMatch;
    int bestScore = -1;

    for (final jsonStr in candidates) {
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is! Map) continue;

        final map = decoded as Map<String, dynamic>;
        int score = 0;

        // Scoring rules for Agent Actions
        if (map.containsKey('answer')) {
          score = 10; // High priority: explicit answer
        } else if (map.containsKey('spawn_subtasks')) {
          score = 10; // High priority: subtask spawning
        } else if (map.containsKey('tool')) {
          if (map.containsKey('args')) {
            score = 10; // High priority: complete tool call
          } else {
            score = 5; // Medium priority: partial tool call (missing args)
          }
        } else if (map.containsKey('think')) {
          score = 2; // Low priority: think block (usually handled by tags)
        } else {
          score = 1; // Generic JSON object
        }

        // Prefer higher score. If tied, prefer the LATER one (heuristic: explanation then action)
        if (score >= bestScore) {
          bestScore = score;
          bestMatch = jsonStr;
        }
      } catch (e) {
        // Not valid JSON, ignore
      }
    }

    if (bestMatch != null) return bestMatch;
  }

  // Step 4: Fallback to opposite structure (e.g. array when object expected)
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

/// Checks if a string likely contains an agent action key (without parsing).
/// Use this for fallback heuristics when JSON parsing fails.
bool looksLikeAgentAction(String content) {
  final lower = content.toLowerCase();
  // We check for "key": pattern to be slightly more confident it's a JSON key
  return lower.contains('"answer"') ||
      lower.contains('"tool"') ||
      lower.contains('"think"') ||
      lower.contains('"spawn_subtasks"');
}
