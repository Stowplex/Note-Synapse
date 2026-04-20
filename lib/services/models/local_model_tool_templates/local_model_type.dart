/// Discriminator used by [FunctionCallFormatFactory] to select the right
/// tool-call parser for each MNN-backed local model family.
enum LocalModelFamily {
  /// Qwen 3.5 / Qwen3-VL — emits `<tool_call>{...}</tool_call>` (JSON) or the
  /// fine-tuned XML variant with `<function=...>` nested tags.
  qwen,

  /// Gemma 4 — no built-in tool template; we prompt-engineer
  /// `<tool_code>{...}</tool_code>` and parse it as JSON.
  gemma,
}
