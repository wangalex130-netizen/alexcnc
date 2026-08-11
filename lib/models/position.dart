/// Work / machine coordinate position in millimetres.
class Position {
  final double x;
  final double y;
  final double z;

  const Position({this.x = 0, this.y = 0, this.z = 0});

  Position copyWith({double? x, double? y, double? z}) =>
      Position(x: x ?? this.x, y: y ?? this.y, z: z ?? this.z);
}
