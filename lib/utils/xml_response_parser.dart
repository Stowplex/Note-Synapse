/// Utilities for parsing XML-based agent responses from LLMs.
///
/// This provides robust XML extraction for agent actions that is more
/// reliable than JSON parsing for longer LLM responses.
import 'dart:convert';

import 'package:json_repair_flutter/json_repair_flutter.dart';

import 'think_tag_utils.dart';

/// Valid action types for agent responses.
const kValidActionTypes = {'tool', 'answer', 'think', 'spawn_subtasks'};

/// Result of parsing an XML agent response.
class XmlAgentResponse {
  /// Content of <MyThought> element.
  final String? thought;

  /// Action type from <Action type="..."> attribute.
  /// One of: "tool", "answer", "think", "spawn_subtasks".
  final String? actionType;

  /// For type="tool": content of <ToolName> element.
  final String? toolName;

  /// Raw content of <Content> element.
  final String? content;

  /// For tool/spawn_subtasks: parsed & validated JSON from Content.
  final dynamic parsedContent;

  /// Error message if parsing failed.
  final String? parseError;

  /// Whether the response contained an Action tag that was malformed.
  /// - true: An <Action type="..."> tag was found but had structural errors
  ///   (missing ToolName, empty Content, invalid JSON, etc.). This is a
  ///   strict error that should be reported back to the LLM.
  /// - false: No Action tag was found at all, which might be acceptable
  ///   for certain task types (e.g., final deliverable returning plain text).
  final bool isMalformedAction;

  const XmlAgentResponse({
    this.thought,
    this.actionType,
    this.toolName,
    this.content,
    this.parsedContent,
    this.parseError,
    this.isMalformedAction = false,
  });

  /// Creates an error response for a missing Action tag.
  factory XmlAgentResponse.error(String error) =>
      XmlAgentResponse(parseError: error, isMalformedAction: false);

  /// Creates an error response for a malformed Action tag.
  /// This indicates the LLM attempted the correct format but made errors.
  factory XmlAgentResponse.malformedAction(String error) =>
      XmlAgentResponse(parseError: error, isMalformedAction: true);

  /// Whether the response is valid (has action type and no errors).
  bool get isValid => actionType != null && parseError == null;

  /// Whether parsing encountered an error.
  bool get hasError => parseError != null;

  @override
  String toString() {
    if (hasError) return 'XmlAgentResponse.error($parseError)';
    return 'XmlAgentResponse(type=$actionType, tool=$toolName)';
  }
}

/// Parses XML agent response from LLM output.
///
/// Expected format:
/// ```
/// <MyThought>reasoning here</MyThought>
/// <Action type="tool|answer|think|spawn_subtasks">
///   <ToolName>tool_name</ToolName>  <!-- only for type="tool" -->
///   <Content>action content</Content>
/// </Action>
/// ```
///
/// For `tool` and `spawn_subtasks` action types, the Content is expected
/// to be valid JSON. Code fences are stripped and `jsonRepair` is used
/// as fallback for malformed JSON.
///
/// Returns [XmlAgentResponse] with parsed data or error message.
XmlAgentResponse parseXmlAgentResponse(String response) {
  // Step 1: Strip <think> tags (from reasoning models)
  final stripped = stripThinkTags(response);
  final content = stripped.cleanedContent;

  // Step 2: Extract <MyThought> content (optional)
  final thoughtMatch = RegExp(
    r'<MyThought>(.*?)</MyThought>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(content);
  final thought = thoughtMatch?.group(1)?.trim();

  // Step 3: Extract <Action> element with type attribute
  // Use [^"]* to allow empty type (which will be caught as invalid later)
  final actionMatch = RegExp(
    r'<Action\s+type\s*=\s*"([^"]*)"[^>]*>(.*?)</Action>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(content);

  if (actionMatch == null) {
    // Try alternate formats (single quotes)
    final altActionMatch = RegExp(
      r"<Action\s+type\s*=\s*'([^']*)'[^>]*>(.*?)</Action>",
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(content);

    if (altActionMatch == null) {
      // Check if there's an Action-like tag that's malformed
      // (e.g., <Action> without type, or <Action type=something> without quotes)
      final malformedActionPattern = RegExp(
        r'<Action[^>]*>',
        caseSensitive: false,
      );
      if (malformedActionPattern.hasMatch(content)) {
        return XmlAgentResponse.malformedAction(
          'Found <Action> tag but missing or malformed type attribute. '
          'Expected format: <Action type="tool|answer|think|spawn_subtasks">',
        );
      }

      return XmlAgentResponse.error(
        'Missing <Action type="...">...</Action> element. '
        'Your response must include an Action element with a type attribute. '
        'Valid types: tool, answer, think, spawn_subtasks.',
      );
    }
    // Use alternate match
    return _parseActionContent(
      thought: thought,
      actionType: altActionMatch.group(1)!.trim().toLowerCase(),
      actionBody: altActionMatch.group(2)!,
    );
  }

  return _parseActionContent(
    thought: thought,
    actionType: actionMatch.group(1)!.trim().toLowerCase(),
    actionBody: actionMatch.group(2)!,
  );
}

/// Internal helper to parse the body of an Action element.
/// NOTE: All errors returned from this function use `malformedAction`
/// because we already matched an Action tag - errors here mean it's malformed.
XmlAgentResponse _parseActionContent({
  required String? thought,
  required String actionType,
  required String actionBody,
}) {
  // Validate action type
  if (!kValidActionTypes.contains(actionType)) {
    return XmlAgentResponse.malformedAction(
      'Invalid action type "$actionType". '
      'Valid types: ${kValidActionTypes.join(", ")}.',
    );
  }

  // Extract <ToolName> for tool actions
  String? toolName;
  if (actionType == 'tool') {
    final toolNameMatch = RegExp(
      r'<ToolName>(.*?)</ToolName>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(actionBody);

    if (toolNameMatch == null) {
      return XmlAgentResponse.malformedAction(
        'Action type="tool" requires a <ToolName> element. '
        'Example: <ToolName>search_notes</ToolName>',
      );
    }
    toolName = toolNameMatch.group(1)?.trim();
    if (toolName == null || toolName.isEmpty) {
      return XmlAgentResponse.malformedAction(
        '<ToolName> element is empty. Provide the tool name to call.',
      );
    }
  }

  // Extract <Content> element
  final contentMatch = RegExp(
    r'<Content>(.*?)</Content>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(actionBody);

  String? rawContent = contentMatch?.group(1);

  // For 'answer' type, we allow missing <Content> tag and treat the body as content
  if (actionType == 'answer' && rawContent == null) {
    rawContent = actionBody.trim();
  }

  // Content is required for all action types except think (where it's optional)
  if (rawContent == null && actionType != 'think') {
    return XmlAgentResponse.malformedAction(
      'Missing <Content> element in Action. '
      'Provide your ${_contentDescriptionForType(actionType)} inside <Content>...</Content>.',
    );
  }

  rawContent = rawContent?.trim();

  // For tool and spawn_subtasks, parse and validate JSON content
  dynamic parsedContent;
  if (actionType == 'tool' || actionType == 'spawn_subtasks') {
    if (rawContent == null || rawContent.isEmpty) {
      return XmlAgentResponse.malformedAction(
        'Empty <Content> for $actionType action. '
        '${_jsonSchemaHintForType(actionType)}',
      );
    }

    final jsonResult = _parseJsonContent(rawContent, actionType);
    if (jsonResult.error != null) {
      return XmlAgentResponse.malformedAction(jsonResult.error!);
    }
    parsedContent = jsonResult.parsed;
  }

  return XmlAgentResponse(
    thought: thought,
    actionType: actionType,
    toolName: toolName,
    content: rawContent,
    parsedContent: parsedContent,
  );
}

/// Result of JSON parsing attempt.
class _JsonParseResult {
  final dynamic parsed;
  final String? error;

  const _JsonParseResult({this.parsed, this.error});
}

/// Parses JSON from Content element, with code fence stripping and repair.
_JsonParseResult _parseJsonContent(String content, String actionType) {
  // Strip code fences if present: ```json ... ``` or ``` ... ```
  String jsonStr = content;
  final fenceMatch = RegExp(
    r'```(?:json)?\s*([\s\S]*?)\s*```',
    caseSensitive: false,
  ).firstMatch(content);

  if (fenceMatch != null) {
    jsonStr = fenceMatch.group(1)!.trim();
  }

  // Try standard JSON decode first
  dynamic decoded;
  try {
    decoded = jsonDecode(jsonStr);
  } catch (e) {
    // Fallback to jsonRepair
    try {
      decoded = repairJson(jsonStr);
    } catch (repairError) {
      return _JsonParseResult(
        error:
            'Invalid JSON in <Content>: ${e.toString().split('\n').first}. '
            '${_jsonSchemaHintForType(actionType)}',
      );
    }
  }

  // Validate schema based on action type
  return _validateJsonSchema(decoded, actionType);
}

/// Validates parsed JSON against expected schema for the action type.
_JsonParseResult _validateJsonSchema(dynamic decoded, String actionType) {
  if (actionType == 'tool') {
    if (decoded is! Map<String, dynamic>) {
      return _JsonParseResult(
        error:
            'Tool <Content> must be a JSON object with tool arguments. '
            'Example: {"query": "search term", "limit": 10}',
      );
    }
    return _JsonParseResult(parsed: decoded);
  }

  if (actionType == 'spawn_subtasks') {
    if (decoded is! List) {
      return _JsonParseResult(
        error:
            'spawn_subtasks <Content> must be a JSON array of subtask objects. '
            'Example: [{"description": "Task 1", "tools": ["search"]}]',
      );
    }

    // Validate each subtask has required fields
    for (int i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is! Map<String, dynamic>) {
        return _JsonParseResult(
          error:
              'Subtask at index $i is not a JSON object. '
              'Each subtask must be: {"description": "...", "tools": [...]}',
        );
      }
      if (!item.containsKey('description') || item['description'] == null) {
        return _JsonParseResult(
          error:
              'Subtask at index $i is missing required "description" field. '
              'Each subtask must have: {"description": "...", "tools": [...]}',
        );
      }
      if (item['description'] is! String ||
          (item['description'] as String).isEmpty) {
        return _JsonParseResult(
          error:
              'Subtask at index $i has empty or invalid "description". '
              'Description must be a non-empty string.',
        );
      }
    }
    return _JsonParseResult(parsed: decoded);
  }

  // Should not reach here
  return _JsonParseResult(parsed: decoded);
}

/// Returns a description of what Content should contain for the action type.
String _contentDescriptionForType(String actionType) {
  switch (actionType) {
    case 'tool':
      return 'tool arguments as JSON';
    case 'answer':
      return 'final answer in markdown';
    case 'think':
      return 'analysis or reasoning';
    case 'spawn_subtasks':
      return 'subtask array as JSON';
    default:
      return 'content';
  }
}

/// Returns schema hint for JSON-based action types.
String _jsonSchemaHintForType(String actionType) {
  if (actionType == 'tool') {
    return 'Content must be a JSON object with tool arguments. '
        'Example: {"query": "search term"}';
  }
  if (actionType == 'spawn_subtasks') {
    return 'Content must be a JSON array of subtasks. '
        'Example: [{"description": "Research X", "tools": ["search"]}]';
  }
  return '';
}
