/// Enum representing different model types
enum ModelType {
  gemini('gemini', 'Gemini'),
  openaiCompatible('openai_compatible', 'OpenAI Compatible'),
  localMnn('local_mnn', 'Local Model');

  const ModelType(this.id, this.displayName);

  final String id;
  final String displayName;

  /// Get model type from ID
  static ModelType? fromId(String id) {
    for (final type in ModelType.values) {
      if (type.id == id) return type;
    }
    return null;
  }

  /// Get all available model types
  static List<ModelType> get all => ModelType.values;

  @override
  String toString() => displayName;
}
