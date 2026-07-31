/// An item in the cloud model library (Core 4).
class LibraryItem {
  final String id;
  final String title;
  final String author;
  final String? imageUrl;
  final bool isPublic; // true = 灵感共享库, false = 我的云端空间
  final String? materialPreset;

  const LibraryItem({
    required this.id,
    required this.title,
    this.author = '',
    this.imageUrl,
    required this.isPublic,
    this.materialPreset,
  });
}
