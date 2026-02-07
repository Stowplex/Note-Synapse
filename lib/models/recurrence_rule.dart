import 'dart:convert';

enum RecurrenceType { none, weekly, interval }

class RecurrenceRule {
  final RecurrenceType type;
  final List<int>? daysOfWeek; // 1 = Monday, 7 = Sunday
  final int? intervalDays;

  RecurrenceRule({required this.type, this.daysOfWeek, this.intervalDays});

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      if (daysOfWeek != null) 'days': daysOfWeek,
      if (intervalDays != null) 'interval': intervalDays,
    };
  }

  factory RecurrenceRule.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String;
    final type = RecurrenceType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => RecurrenceType.none,
    );

    return RecurrenceRule(
      type: type,
      daysOfWeek: (json['days'] as List<dynamic>?)?.cast<int>(),
      intervalDays: json['interval'] as int?,
    );
  }

  static String? encode(RecurrenceRule? rule) {
    if (rule == null || rule.type == RecurrenceType.none) return null;
    return jsonEncode(rule.toJson());
  }

  static RecurrenceRule? decode(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      return RecurrenceRule.fromJson(jsonDecode(jsonStr));
    } catch (e) {
      return null;
    }
  }
}
