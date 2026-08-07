/// An item in the cloud model library (Core 4).
///
/// `isPublic == true` => 灵感共享库 (public inspiration);
/// `isPublic == false` => 我的云端空间 (private cloud space).
/// Within the private space, `isHistory` marks a completed-job record.
class LibraryItem {
  final String id;
  final String title;
  final String author;
  final String? imageUrl;
  final bool isPublic; // true = 灵感共享库, false = 我的云端空间
  final String? materialPreset;

  // ---- Inspiration-view extras -------------------------------------------
  final String? category; // 灵感库分类
  final String? duration; // 预估耗时，e.g. "12分30秒"
  final bool isHero; // 是否为焦点大图
  final String? heroTag; // 焦点图角标，e.g. "周末主推干货"

  // ---- My-space-view extras ----------------------------------------------
  final String? syncTime; // 同步时间，e.g. "今天 14:30 同步"
  final bool isHistory; // 成功加工记录（历史复用）

  const LibraryItem({
    required this.id,
    required this.title,
    this.author = '',
    this.imageUrl,
    required this.isPublic,
    this.materialPreset,
    this.category,
    this.duration,
    this.isHero = false,
    this.heroTag,
    this.syncTime,
    this.isHistory = false,
  });

  /// 从云端 REST JSON 解析（字段对齐 docs/PROTOCOL.md §3.1 LibraryItem）。
  factory LibraryItem.fromJson(Map<String, dynamic> j) => LibraryItem(
        id: (j['id'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        author: (j['author'] as String?) ?? '',
        imageUrl: j['imageUrl'] as String?,
        isPublic: j['isPublic'] == true,
        materialPreset: j['materialPreset'] as String?,
        category: j['category'] as String?,
        duration: j['duration'] as String?,
        isHero: j['isHero'] == true,
        heroTag: j['heroTag'] as String?,
        syncTime: j['syncTime'] as String?,
        isHistory: j['isHistory'] == true,
      );
}
