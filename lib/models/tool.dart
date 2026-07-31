/// A tool slot in the ATC magazine (T1..T4).
class Tool {
  final int index; // 1..4
  final String name;
  final String? material;
  final double? lengthMm;
  final bool installed;

  const Tool({
    required this.index,
    this.name = '',
    this.material,
    this.lengthMm,
    this.installed = false,
  });

  Tool copyWith({
    String? name,
    String? material,
    double? lengthMm,
    bool? installed,
  }) =>
      Tool(
        index: index,
        name: name ?? this.name,
        material: material ?? this.material,
        lengthMm: lengthMm ?? this.lengthMm,
        installed: installed ?? this.installed,
      );
}
