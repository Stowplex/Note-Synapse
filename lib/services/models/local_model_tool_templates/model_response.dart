// Local mirror of flutter_gemma's ModelResponse hierarchy (MIT, DenisovAV).
// Kept as plain Dart so the rest of the app can reuse the response contract
// (TextResponse / FunctionCallResponse / ParallelFunctionCallResponse /
// ThinkingResponse) without depending on flutter_gemma.

sealed class ModelResponse {
  const ModelResponse();
}

class TextResponse extends ModelResponse {
  const TextResponse(this.token);

  final String token;

  @override
  String toString() => 'TextResponse("$token")';

  @override
  bool operator ==(Object other) =>
      other is TextResponse && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

class FunctionCallResponse extends ModelResponse {
  const FunctionCallResponse({required this.name, required this.args});

  final String name;
  final Map<String, dynamic> args;

  @override
  String toString() => 'FunctionCallResponse(name: $name, args: $args)';

  @override
  bool operator ==(Object other) =>
      other is FunctionCallResponse && other.name == name && _mapsEqual(other.args, args);

  @override
  int get hashCode => Object.hash(name, args.length);
}

class ParallelFunctionCallResponse extends ModelResponse {
  const ParallelFunctionCallResponse({required this.calls});

  final List<FunctionCallResponse> calls;

  @override
  String toString() => 'ParallelFunctionCallResponse(${calls.length} calls)';
}

class ThinkingResponse extends ModelResponse {
  const ThinkingResponse(this.content);

  final String content;

  @override
  String toString() => 'ThinkingResponse("$content")';

  @override
  bool operator ==(Object other) =>
      other is ThinkingResponse && other.content == content;

  @override
  int get hashCode => content.hashCode;
}

bool _mapsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
