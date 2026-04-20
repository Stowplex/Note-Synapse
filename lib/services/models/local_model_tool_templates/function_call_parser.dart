import 'function_call_format.dart';
import 'json_function_call_format.dart';
import 'local_model_type.dart';
import 'model_response.dart';
import 'qwen_function_call_format.dart';

/// Facade for model-specific tool-call parsing. Picks the right
/// [FunctionCallFormat] for each local model family and dispatches the
/// streaming/parsing calls.
class FunctionCallParser {
  const FunctionCallParser._();

  /// Resolve the parser strategy for a given model family.
  static FunctionCallFormat formatFor(LocalModelFamily? family) {
    switch (family) {
      case LocalModelFamily.qwen:
        return QwenFunctionCallFormat();
      case LocalModelFamily.gemma:
      case null:
        return JsonFunctionCallFormat();
    }
  }

  /// Does the buffer look like the beginning of a tool call?
  static bool isFunctionCallStart(
    String buffer, {
    LocalModelFamily? family,
  }) {
    return formatFor(family).isFunctionCallStart(buffer);
  }

  /// Does the buffer look like it is definitely plain text (not a call)?
  static bool isDefinitelyText(
    String buffer, {
    LocalModelFamily? family,
  }) {
    return formatFor(family).isDefinitelyText(buffer);
  }

  /// Is the buffered call structurally complete and ready to parse?
  static bool isFunctionCallComplete(
    String buffer, {
    LocalModelFamily? family,
  }) {
    return formatFor(family).isFunctionCallComplete(buffer);
  }

  /// Parse a single function call.
  static FunctionCallResponse? parse(
    String text, {
    LocalModelFamily? family,
  }) {
    if (text.trim().isEmpty) return null;
    try {
      return formatFor(family).parse(text);
    } catch (_) {
      return null;
    }
  }

  /// Parse all function calls from a buffer (parallel tool calls).
  static List<FunctionCallResponse> parseAll(
    String text, {
    LocalModelFamily? family,
  }) {
    if (text.trim().isEmpty) return const [];
    try {
      return formatFor(family).parseAll(text);
    } catch (_) {
      return const [];
    }
  }
}
