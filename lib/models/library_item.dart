/// An item in the cloud model library (Core 4).
///
/// `isPublic == true` => 灵感共享库 (public inspiration);
/// `isPublic == false` => 我的云端空间 (private cloud space).
/// Within the private space, `isHistory` marks a completed-job record.
///
/// 字段对齐 `模型库接口文档.md`（`/api/model-library/*`）：
/// 列表卡片 = ModelCard，详情 = ModelDetail（含尺寸/加工参数/刀路地址）。

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
  final String? duration; // 展示用雕刻时长，e.g. "12分30秒"
  final bool isHero; // 是否为焦点大图
  final String? heroTag; // 焦点图角标，e.g. "周末主推干货"

  // ---- My-space-view extras ----------------------------------------------
  final String? syncTime; // 同步时间，e.g. "今天 14:30 同步"
  final bool isHistory; // 成功加工记录（历史复用）

  // ---- 模型库 REST 接口（/api/model-library/*）字段 ----------------------
  final String? coverUrl; // 封面图（列表；= imageUrls 第一张）
  final List<String> imageUrls; // 几张实物图（详情轮播）
  final List<String> tags; // 风格标签
  final String? materialKey; // 默认材质 key（关联材质主表）
  final String? toolId; // 默认刀具 id（关联刀具库）
  final int? durationSec; // 雕刻时长秒数（排序/统计）
  final String? gcodeStatus; // unsliced / sliced（详情页据此判断可否预览）
  final String? description; // 模型简介
  final double widthMm, heightMm, depthMm; // 模型尺寸（驱动调平点数）
  final double boardThicknessMm; // 推荐板材厚度
  final List<RequiredTool> requiredTools; // 有序工序刀具

  // ---- 详情接口独有字段（ModelDetail）-----------------------------------
  final String? tools; // 默认刀具名称串，如 "3.175mm平底刀,1.5mm球头刀"
  final int? recommendedSpindleRpm; // 推荐主轴转速 RPM
  final double? recommendedFeedRate; // 推荐进给速率
  final String? roughingGcodeUrl; // 粗加工刀路文件 URL（可空）
  final String? finishingGcodeUrl; // 精加工刀路文件 URL（可空）
  final String? createTime; // 创建时间，如 2026-08-11 11:59:16
  final String? updateTime; // 更新时间

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
    this.tools,
    this.recommendedSpindleRpm,
    this.recommendedFeedRate,
    this.roughingGcodeUrl,
    this.finishingGcodeUrl,
    this.createTime,
    this.updateTime,
  });

  /// 从云端 REST JSON 解析（字段对齐 模型库接口文档.md）。
  ///
  /// - `id`：后端为 long，统一转 String 以兼容 App 内 Map key / 路由。
  /// - `tools`：逗号分隔的刀具名称串，拆成 [RequiredTool] 供详情/向导展示；
  ///   若同时有结构化 `requiredTools` 数组则优先用数组。
  /// - `gcodeStatus`：后端未直接给，由 roughing/finishing 刀路 URL 是否为空推导。
  factory LibraryItem.fromJson(Map<String, dynamic> j) {
    final reqFromArray = (j['requiredTools'] as List? ?? [])
        .map((e) => e is Map
            ? RequiredTool(
                (e['toolId'] as String? ?? ''), (e['role'] as String? ?? ''))
            : RequiredTool(e.toString(), ''))
        .toList();
    final rawTools = j['tools'];
    final reqFromStr = rawTools is String && rawTools.trim().isNotEmpty
        ? rawTools
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .map((s) => RequiredTool(s, ''))
            .toList()
        : <RequiredTool>[];
    final requiredTools =
        reqFromArray.isNotEmpty ? reqFromArray : reqFromStr;

    final rough = j['roughingGcodeUrl'] as String?;
    final fine = j['finishingGcodeUrl'] as String?;
    final gcodeStatus = (j['gcodeStatus'] as String?) ??
        ((rough != null || fine != null) ? 'sliced' : null);

    return LibraryItem(
      id: j['id']?.toString() ?? '',
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
      materialKey: j['materialKey'] as String?,
      toolId: j['toolId'] as String?,
      durationSec: (j['durationSec'] as num?)?.toInt(),
      gcodeStatus: gcodeStatus,
      description: j['description'] as String?,
      widthMm: (j['widthMm'] as num? ?? 0).toDouble(),
      heightMm: (j['heightMm'] as num? ?? 0).toDouble(),
      depthMm: (j['depthMm'] as num? ?? 0).toDouble(),
      boardThicknessMm: (j['boardThicknessMm'] as num? ?? 0).toDouble(),
      requiredTools: requiredTools,
      previewUrl: j['previewUrl'] as String?,
      tools: rawTools is String ? rawTools : null,
      recommendedSpindleRpm: (j['recommendedSpindleRpm'] as num?)?.toInt(),
      recommendedFeedRate: (j['recommendedFeedRate'] as num?)?.toDouble(),
      roughingGcodeUrl: rough,
      finishingGcodeUrl: fine,
      createTime: j['createTime'] as String?,
      updateTime: j['updateTime'] as String?,
    );
  }

  /// 不可变拷贝（用于 Mock 详情补全等场景）。
  LibraryItem copyWith({
    String? id,
    String? title,
    String? author,
    String? imageUrl,
    bool? isPublic,
    String? materialPreset,
    String? category,
    String? duration,
    bool? isHero,
    String? heroTag,
    String? syncTime,
    bool? isHistory,
    String? coverUrl,
    List<String>? imageUrls,
    List<String>? tags,
    String? materialKey,
    String? toolId,
    int? durationSec,
    String? gcodeStatus,
    String? description,
    double? widthMm,
    double? heightMm,
    double? depthMm,
    double? boardThicknessMm,
    List<RequiredTool>? requiredTools,
    String? previewUrl,
    String? tools,
    int? recommendedSpindleRpm,
    double? recommendedFeedRate,
    String? roughingGcodeUrl,
    String? finishingGcodeUrl,
    String? createTime,
    String? updateTime,
  }) =>
      LibraryItem(
        id: id ?? this.id,
        title: title ?? this.title,
        author: author ?? this.author,
        imageUrl: imageUrl ?? this.imageUrl,
        isPublic: isPublic ?? this.isPublic,
        materialPreset: materialPreset ?? this.materialPreset,
        category: category ?? this.category,
        duration: duration ?? this.duration,
        isHero: isHero ?? this.isHero,
        heroTag: heroTag ?? this.heroTag,
        syncTime: syncTime ?? this.syncTime,
        isHistory: isHistory ?? this.isHistory,
        coverUrl: coverUrl ?? this.coverUrl,
        imageUrls: imageUrls ?? this.imageUrls,
        tags: tags ?? this.tags,
        materialKey: materialKey ?? this.materialKey,
        toolId: toolId ?? this.toolId,
        durationSec: durationSec ?? this.durationSec,
        gcodeStatus: gcodeStatus ?? this.gcodeStatus,
        description: description ?? this.description,
        widthMm: widthMm ?? this.widthMm,
        heightMm: heightMm ?? this.heightMm,
        depthMm: depthMm ?? this.depthMm,
        boardThicknessMm: boardThicknessMm ?? this.boardThicknessMm,
        requiredTools: requiredTools ?? this.requiredTools,
        previewUrl: previewUrl ?? this.previewUrl,
        tools: tools ?? this.tools,
        recommendedSpindleRpm:
            recommendedSpindleRpm ?? this.recommendedSpindleRpm,
        recommendedFeedRate:
            recommendedFeedRate ?? this.recommendedFeedRate,
        roughingGcodeUrl: roughingGcodeUrl ?? this.roughingGcodeUrl,
        finishingGcodeUrl: finishingGcodeUrl ?? this.finishingGcodeUrl,
        createTime: createTime ?? this.createTime,
        updateTime: updateTime ?? this.updateTime,
      );

  /// 列表展示用图：优先 coverUrl，其次 imageUrls[0]，最后兼容旧 imageUrl。
  String? get displayImageUrl =>
      coverUrl ?? (imageUrls.isNotEmpty ? imageUrls.first : imageUrl);
}
