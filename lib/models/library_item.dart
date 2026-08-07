/// An item in the cloud model library (Core 4).
///
/// `isPublic == true` => 灵感共享库 (public inspiration);
/// `isPublic == false` => 我的云端空间 (private cloud space).
/// Within the private space, `isHistory` marks a completed-job record.

import 'task_metadata.dart' show RequiredTool;

class LibraryItem {
  final String id;
  final String title;
  final String author;
  final String? imageUrl; // 兼容旧字段；新数据用 coverUrl
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

  // ---- 模型库 v1.0 新字段（docs/模型库数据格式与接口定义.md）------------
  final String? coverUrl; // 封面图（列表；= imageUrls 第一张）
  final List<String> imageUrls; // 几张实物图（详情轮播）
  final List<String> tags; // 风格标签
  final String? difficulty; // 难度：入门/进阶/高手
  final String? materialKey; // 默认材质 key（关联材质主表）
  final String? toolId; // 默认刀具 id（关联刀具库）
  final int? durationSec; // 雕刻时长秒数（排序/统计）
  final String? gcodeStatus; // unsliced / sliced
  final String? description; // 模型简介
  final double widthMm, heightMm, depthMm; // 模型尺寸（驱动调平点数）
  final double boardThicknessMm; // 推荐板材厚度
  final List<RequiredTool> requiredTools; // 有序工序刀具
  final String? previewUrl; // 2D 刀路预览矢量 JSON 地址

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
    this.coverUrl,
    this.imageUrls = const [],
    this.tags = const [],
    this.difficulty,
    this.materialKey,
    this.toolId,
    this.durationSec,
    this.gcodeStatus,
    this.description,
    this.widthMm = 0,
    this.heightMm = 0,
    this.depthMm = 0,
    this.boardThicknessMm = 0,
    this.requiredTools = const [],
    this.previewUrl,
  });

  /// 从云端 REST JSON 解析（字段对齐 docs/模型库数据格式与接口定义.md）。
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
        coverUrl: j['coverUrl'] as String?,
        imageUrls: (j['imageUrls'] as List? ?? [])
            .map((e) => e.toString())
            .toList(),
        tags: (j['tags'] as List? ?? []).map((e) => e.toString()).toList(),
        difficulty: j['difficulty'] as String?,
        materialKey: j['materialKey'] as String?,
        toolId: j['toolId'] as String?,
        durationSec: (j['durationSec'] as num?)?.toInt(),
        gcodeStatus: j['gcodeStatus'] as String?,
        description: j['description'] as String?,
        widthMm: (j['widthMm'] as num? ?? 0).toDouble(),
        heightMm: (j['heightMm'] as num? ?? 0).toDouble(),
        depthMm: (j['depthMm'] as num? ?? 0).toDouble(),
        boardThicknessMm: (j['boardThicknessMm'] as num? ?? 0).toDouble(),
        requiredTools: (j['requiredTools'] as List? ?? [])
            .map((e) => RequiredTool(
                  (e['toolId'] as String? ?? ''),
                  (e['role'] as String? ?? ''),
                ))
            .toList(),
        previewUrl: j['previewUrl'] as String?,
      );

  /// 列表展示用图：优先 coverUrl，其次 imageUrls[0]，最后兼容旧 imageUrl。
  String? get displayImageUrl =>
      coverUrl ?? (imageUrls.isNotEmpty ? imageUrls.first : imageUrl);
}
