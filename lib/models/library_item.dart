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
}
