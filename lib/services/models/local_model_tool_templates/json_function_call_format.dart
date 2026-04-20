import 'function_call_format.dart';
import 'json_parsing_utils.dart';
import 'model_response.dart';

/// JSON-based function-call format used by Gemma-4 (and as the default
/// fallback). Ported from flutter_gemma's JsonFunctionCallFormat.
///
/// Supported fences:
///   - `<tool_code>JSON</tool_code>`             (XML-style)
///   - ` ```tool_code\nJSON\n``` `               (Gemma 3 markdown)
///   - ` ```json\nJSON\n``` `                    (markdown)
///   - ` ```\nJSON\n``` ` (if body looks like a call)
///   - Direct JSON: `{"name": "...", "parameters": {...}}`
class JsonFunctionCallFormat extends FunctionCallFormat {
  @override
  bool isFunctionCallStart(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;
    return clean.startsWith('{') ||
        clean.startsWith('```') ||
        clean.startsWith('<tool_code>');
  }

  @override
  bool isDefinitelyText(String buffer) {
    return JsonParsingUtils.isDefinitelyText(buffer);
  }

  @override
  bool isFunctionCallComplete(String buffer) {
    final clean = buffer.trim();
    if (clean.isEmpty) return false;

    if (clean.startsWith('{') && clean.endsWith('}')) {
      return JsonParsingUtils.isBalancedJson(clean);
    }
    if (clean.contains('```json') && clean.endsWith('```')) return true;
    if (clean.contains('```tool_code') && clean.endsWith('```')) return true;
    if (clean.contains('<tool_code>') && clean.contains('</tool_code>')) {
      return true;
    }
    return false;
  }

  @override
  FunctionCallResponse? parse(String text) {
    if (text.trim().isEmpty) return null;
    final content = JsonParsingUtils.cleanModelResponse(text);
    return _parseToolCodeXmlBlock(content) ??
        _parseToolCodeMarkdownBlock(content) ??
        _parseMarkdownBlock(content) ??
        _parseDirectJson(content);
  }

  @override
  List<FunctionCallResponse> parseAll(String text) {
    if (text.trim().isEmpty) return const [];
    final content = JsonParsingUtils.cleanModelResponse(text);
    final results = <FunctionCallResponse>[];

    final xmlRegex =
        RegExp(r'<tool_code>\s*([\s\S]*?)\s*</tool_code>', multiLine: true);
    for (final match in xmlRegex.allMatches(content)) {
      final result = JsonParsingUtils.parseJsonString(match.group(1)!.trim());
      if (result != null) results.add(result);
    }
    if (results.isNotEmpty) return results;

    final mdToolCodeRegex =
        RegExp(r'```tool_code\s*([\s\S]*?)\s*```', multiLine: true);
    for (final match in mdToolCodeRegex.allMatches(content)) {
      final result = JsonParsingUtils.parseJsonString(match.group(1)!.trim());
      if (result != null) results.add(result);
    }
    if (results.isNotEmpty) return results;

    final mdJsonRegex =
        RegExp(r'```json\s*([\s\S]*?)\s*```', multiLine: true);
    for (final match in mdJsonRegex.allMatches(content)) {
      final result = JsonParsingUtils.parseJsonString(match.group(1)!.trim());
      if (result != null) results.add(result);
    }
    if (results.isNotEmpty) return results;

    return JsonParsingUtils.parseMultipleJsonObjects(content);
  }

  FunctionCallResponse? _parseToolCodeXmlBlock(String content) {
    final regex =
        RegExp(r'<tool_code>\s*([\s\S]*?)\s*</tool_code>', multiLine: true);
    final match = regex.firstMatch(content);
    if (match != null) {
      return JsonParsingUtils.parseJsonString(match.group(1)!.trim());
    }
    return null;
  }

  FunctionCallResponse? _parseToolCodeMarkdownBlock(String content) {
    final regex =
        RegExp(r'```tool_code\s*([\s\S]*?)\s*```', multiLine: true);
    final match = regex.firstMatch(content);
    if (match != null) {
      return JsonParsingUtils.parseJsonString(match.group(1)!.trim());
    }
    return null;
  }

  FunctionCallResponse? _parseMarkdownBlock(String content) {
    var regex = RegExp(r'```json\s*([\s\S]*?)\s*```', multiLine: true);
    var match = regex.firstMatch(content);
    if (match != null) {
      return JsonParsingUtils.parseJsonString(match.group(1)!.trim());
    }

    regex = RegExp(r'```\s*([\s\S]*?)\s*```', multiLine: true);
    match = regex.firstMatch(content);
    if (match != null) {
      final jsonStr = match.group(1)!.trim();
      if (jsonStr.startsWith('{') && jsonStr.contains('"name"')) {
        return JsonParsingUtils.parseJsonString(jsonStr);
      }
    }
    return null;
  }

  FunctionCallResponse? _parseDirectJson(String content) {
    final trimmed = content.trim();
    if (trimmed.startsWith('{') && trimmed.contains('"name"')) {
      return JsonParsingUtils.parseJsonString(trimmed);
    }
    return null;
  }
}
