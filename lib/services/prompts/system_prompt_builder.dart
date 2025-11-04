import 'package:intl/intl.dart';

import 'prompt_models.dart';

/// Centralized builder for system prompts that establishes persona, temporal
/// context, and task-specific guidance.
class SystemPromptBuilder {
  static const String defaultPersona =
      'You are Note Synapse, an attentive, context-aware assistant focused on '
      'helping users reason about their notes, tasks, and creative work. '
      'Respond with clear structure and call out assumptions when information '
      'is missing.';

  /// Build a system message including persona, current date/time, and optional
  /// task-specific context or guidelines.
  static PromptMessage build({
    String? persona,
    String? taskContext,
    List<String> guidelines = const [],
    DateTime? now,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('Persona: ${persona ?? defaultPersona}');

    final timestamp = formatTimestamp(now ?? DateTime.now());
    buffer.writeln('Conversation start at: $timestamp');

    if ((taskContext ?? '').trim().isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Task Context:');
      buffer.writeln(taskContext!.trim());
    }

    if (guidelines.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Guidelines:');
      for (final line in guidelines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.startsWith('-')) {
          buffer.writeln(trimmed);
        } else {
          buffer.writeln('- $trimmed');
        }
      }
    }

    return PromptMessage(
      role: PromptRole.system,
      content: buffer.toString().trim(),
    );
  }

  static String formatTimestamp(DateTime dateTime) {
    final local = dateTime.toLocal();
    final datePart = DateFormat('yyyy-MM-dd (EEEE)').format(local);
    final timePart = DateFormat('HH:mm:ss').format(local);

    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = offset.inMinutes.remainder(60).abs().toString().padLeft(2, '0');

    return '$datePart $timePart UTC$sign$hours:$minutes';
  }
}

