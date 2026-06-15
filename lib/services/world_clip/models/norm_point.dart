/// A point in normalized image coordinates (0..1, top-left origin).
class NormPoint {
  final double x;
  final double y;
  const NormPoint(this.x, this.y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
  factory NormPoint.fromJson(Map<String, dynamic> j) =>
      NormPoint((j['x'] as num).toDouble(), (j['y'] as num).toDouble());

  @override
  bool operator ==(Object other) =>
      other is NormPoint && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
}
