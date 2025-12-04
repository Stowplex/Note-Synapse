import 'model_config.dart';

class GenerationContext {
  GenerationContext({Map<String, dynamic>? values})
    : _values = values != null ? Map<String, dynamic>.from(values) : {};

  final Map<String, dynamic> _values;

  /// Immutable snapshot of all stored values.
  Map<String, dynamic> get values => Map.unmodifiable(_values);

  /// Retrieves a value from the context.
  T? getValue<T>(String key) => _values[key] as T?;

  /// Sets or removes a value in the context.
  void setValue(String key, dynamic value) {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  /// Ensures a requestId exists and returns it.
  String ensureRequestId() {
    final existing = requestId;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final newId = DateTime.now().millisecondsSinceEpoch.toString();
    _values['requestId'] = newId;
    return newId;
  }

  /// Optional request identifier for correlating logs.
  String? get requestId => _values['requestId'] as String?;
  set requestId(String? value) => setValue('requestId', value);

  /// Creates a shallow copy of the current context map.
  GenerationContext fork() => GenerationContext(values: _values);

  /// Optional model configuration override for this specific request.
  ModelConfig? get modelOverride => _values['modelOverride'] as ModelConfig?;
  set modelOverride(ModelConfig? value) => setValue('modelOverride', value);
}
