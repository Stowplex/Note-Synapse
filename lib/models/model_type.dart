/// Enum representing different model types
enum ModelType {
  gemini25Flash('gemini_2_5_flash', 'Gemini 2.5 Flash'),
  gemma3n('gemma_3n', 'Gemma 3n'),
  qwen25('qwen_2_5', 'Qwen 2.5'),
  openaiCompatible('openai_compatible', 'OpenAI Compatible');

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
