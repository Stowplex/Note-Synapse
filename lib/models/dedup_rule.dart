class DedupRule {
  final String id;
  final String leftTag;
  final String rightTag;

  DedupRule({
    required this.id,
    required this.leftTag,
    required this.rightTag,
  });

  DedupRule copyWith({
    String? id,
    String? leftTag,
    String? rightTag,
  }) {
    return DedupRule(
      id: id ?? this.id,
      leftTag: leftTag ?? this.leftTag,
      rightTag: rightTag ?? this.rightTag,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'leftTag': leftTag,
      'rightTag': rightTag,
    };
  }

  factory DedupRule.fromJson(Map<String, dynamic> json) {
    return DedupRule(
      id: json['id'] as String,
      leftTag: json['leftTag'] as String,
      rightTag: json['rightTag'] as String,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DedupRule &&
        other.id == id &&
        other.leftTag == leftTag &&
        other.rightTag == rightTag;
  }

  @override
  int get hashCode {
    return id.hashCode ^ leftTag.hashCode ^ rightTag.hashCode;
  }

  @override
  String toString() {
    return 'DedupRule(id: $id, leftTag: $leftTag, rightTag: $rightTag)';
  }
}

