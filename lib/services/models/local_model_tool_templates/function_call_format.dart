import 'model_response.dart';

/// Strategy interface for model-specific function call parsing. Ported from
/// flutter_gemma (MIT, DenisovAV) and trimmed to the subset Note-Synapse
/// actually uses.
///
/// Each MNN-backed model family uses a different surface for tool calls.
/// Implementations handle stream detection, completion checking, and parsing.
abstract class FunctionCallFormat {
  /// Check if buffer starts with a function call indicator.
  bool isFunctionCallStart(String buffer);

  /// Check if buffer content is definitely plain text (not a function call).
  bool isDefinitelyText(String buffer);

  /// Check if the function call structure is complete and ready to parse.
  bool isFunctionCallComplete(String buffer);

  /// Parse a single function call from text. Returns null if not valid.
  FunctionCallResponse? parse(String text);

  /// Parse all function calls from text (for parallel tool calls).
  /// Default delegates to [parse].
  List<FunctionCallResponse> parseAll(String text) {
    final result = parse(text);
    return result != null ? [result] : [];
  }
}
