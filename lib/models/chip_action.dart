import 'package:flutter/foundation.dart';

/// A single tappable action chip emitted by the AI in a fenced ` ```chips `
/// block. Two-field shape:
///
/// - [label]: short display text (≤5 words; truncated with ellipsis at render
///   time if exceeded). What the user sees on the chip itself.
/// - [prompt]: the full prompt the AI receives when the chip is tapped. Can
///   be long, persona-laden, calibration-aware. Never displayed directly;
///   revealed via hover (desktop) or long-press (mobile) preview.
///
/// The decoupling lets the model emit a concise visual affordance while still
/// controlling the rich instruction the next AI turn receives. Tapping a chip
/// forks the conversation; the new conversation's title becomes [label] and
/// the first user message becomes [prompt].
@immutable
class ChipAction {
  final String label;
  final String prompt;

  const ChipAction({required this.label, required this.prompt});

  @override
  bool operator ==(Object other) =>
      other is ChipAction && other.label == label && other.prompt == prompt;

  @override
  int get hashCode => Object.hash(label, prompt);

  @override
  String toString() => 'ChipAction(label: $label, prompt: ${prompt.length}c)';
}
