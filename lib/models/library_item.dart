/// An item in the cloud model library (Core 4).
///
/// `isPublic == true` => 灵感共享库 (public inspiration);
/// `isPublic == false` => 我的云端空间 (private cloud space).
/// Within the private space, `isHistory` marks a completed-job record.

import 'task_metadata.dart' show RequiredTool, TaskMetadata;

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
  final String? materialKey; // 默认材质 key（关联材质主表）
  final String? toolId; // 默认刀具 id（关联刀具库）
  final String? tools; // 后端逗号分隔工序刀具串，如 "ballnose-1.5mm,vbit-30"
  final int? durationSec; // 雕刻时长秒数（排序/统计）
  final String? gcodeStatus; // unsliced / sliced
  final String? description; // 模型简介
  final double widthMm, heightMm, depthMm; // 模型尺寸（驱动调平点数）
  final double boardThicknessMm; // 推荐板材厚度
  final List<RequiredTool> requiredTools; // 有序工序刀具
  final String? previewUrl; // 2D 刀路预览矢量 JSON 地址

  // ---- 模型库接口补充（推荐加工参数，由云端下发的真实值）----
  final int? recommendedSpindleRpm; // 推荐主轴转速 (RPM)
  final double? recommendedFeedRate; // 推荐进给速度 (mm/min)

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
    this.tools,
    this.durationSec,
    this.gcodeStatus,
    this.description,
    this.widthMm = 0,
    this.heightMm = 0,
    this.depthMm = 0,
    this.boardThicknessMm = 0,
    this.requiredTools = const [],
    this.previewUrl,
    this.recommendedSpindleRpm,
    this.recommendedFeedRate,
  });

  /// 从云端 REST JSON 解析（字段对齐 docs/模型库数据格式与接口定义.md）。
  ///
  /// 注意：后端 `id` 实测为 int（如 6），统一 toString() 成 String，
  /// 避免 `(j['id'] as String?)` 对 int 强转抛 CastError。
  factory LibraryItem.fromJson(Map<String, dynamic> j) => LibraryItem(
        id: (j['id']?.toString()) ?? '',
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
        tools: j['tools'] as String?,
        durationSec: (j['durationSec'] as num?)?.toInt(),
        // gcodeStatus 后端不回传时，按约定由刀路 URL 推导（任一非空即已切片）。
        gcodeStatus: (j['gcodeStatus'] as String?) ??
            ((j['roughingGcodeUrl'] != null || j['finishingGcodeUrl'] != null)
                ? 'sliced'
                : 'unsliced'),
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
        recommendedSpindleRpm: (j['recommendedSpindleRpm'] as num?)?.toInt(),
        recommendedFeedRate: (j['recommendedFeedRate'] as num?)?.toDouble(),
      );

  /// 列表展示用图：优先 coverUrl，其次 imageUrls[0]，最后兼容旧 imageUrl。
  String? get displayImageUrl =>
      coverUrl ?? (imageUrls.isNotEmpty ? imageUrls.first : imageUrl);

  /// 把后端可能为空的 `materialKey` 映射到本地材质表 key。
  /// 优先用显式 materialKey；否则按 materialPreset / category 模糊匹配。
  String get effectiveMaterialKey {
    if (materialKey != null && materialKey!.isNotEmpty) return materialKey!;
    final clue = '${materialPreset ?? ''} ${category ?? ''}'.toLowerCase();
    if (clue.contains('亚克力') || clue.contains('acrylic')) return 'acrylic';
    if (clue.contains('皮革') || clue.contains('leather')) return 'leather';
    if (clue.contains('pcb') || clue.contains('电路')) return 'pcb';
    if (clue.contains('金属') || clue.contains('metal') ||
        clue.contains('铝') || clue.contains('alu')) return 'alu';
    if (clue.contains('铜') || clue.contains('brass')) return 'brass';
    if (clue.contains('木') || clue.contains('wood')) return 'pine';
    return 'pine';
  }

  /// 把后端 `tools` 逗号字符串或 `requiredTools` 数组解析成本地工序刀具列表。
  List<RequiredTool> get effectiveRequiredTools {
    if (requiredTools.isNotEmpty) return requiredTools;
    // 后端常用 comma-separated tool ids in `tools`
    final raw = (tools?.isNotEmpty ?? false)
        ? tools!
        : ((toolId?.isNotEmpty ?? false) ? toolId! : '');
    final ids = raw.isEmpty
        ? <String>[]
        : raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (ids.isEmpty) return const [];
    return ids.asMap().entries.map((e) {
      final role = e.key == 0 ? '粗雕' : (e.key == ids.length - 1 ? '精雕' : '半精加工');
      return RequiredTool(_mapToolId(e.value), role);
    }).toList();
  }

  /// 把后端 toolId（如 ballnose-1.5mm / vbit-30）映射到本地刀库 id。
  static String _mapToolId(String raw) {
    final id = raw.toLowerCase().trim();
    final Map<String, String> exact = {
      'ballnose-1.5mm': 't_ball_15',
      'vbit-30': 't_v60',
      'flat-3.175mm': 't_flat_3175',
      'flat-3.175': 't_flat_3175',
    };
    if (exact.containsKey(id)) return exact[id]!;
    if (id.contains('ball') || id.contains('球')) return 't_ball_15';
    if (id.contains('vbit') || id.contains('v-') || id.contains('v型') || id.contains('v刀')) return 't_v60';
    if (id.contains('flat') || id.contains('平底') || id.contains('平刀')) return 't_flat_3175';
    if (id.contains('single') || id.contains('单刃')) return 't_o_single_3175';
    if (id.contains('2flute') || id.contains('双刃')) return 't_2flute_3175';
    if (id.contains('tip') || id.contains('尖')) return 't_vtip_08';
    return id;
  }

  /// 转成向导内部使用的 TaskMetadata（不再依赖 /api/v1/tasks/{id}）。
  TaskMetadata toTaskMetadata() => TaskMetadata(
        id: id,
        name: title,
        widthMm: widthMm,
        heightMm: heightMm,
        depthMm: depthMm,
        boardThicknessMm: boardThicknessMm,
        recommendedSpindleRpm: recommendedSpindleRpm?.toDouble(),
        recommendedFeedRate: recommendedFeedRate,
        thumbnailUrl: displayImageUrl,
        defaultMaterialKey: effectiveMaterialKey,
        defaultToolId: effectiveRequiredTools.isNotEmpty ? effectiveRequiredTools.first.toolId : toolId,
        requiredTools: effectiveRequiredTools,
      );

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
    String? tools,
    int? durationSec,
    String? gcodeStatus,
    String? description,
    double? widthMm,
    double? heightMm,
    double? depthMm,
    double? boardThicknessMm,
    List<RequiredTool>? requiredTools,
    String? previewUrl,
    int? recommendedSpindleRpm,
    double? recommendedFeedRate,
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
        tools: tools ?? this.tools,
        durationSec: durationSec ?? this.durationSec,
        gcodeStatus: gcodeStatus ?? this.gcodeStatus,
        description: description ?? this.description,
        widthMm: widthMm ?? this.widthMm,
        heightMm: heightMm ?? this.heightMm,
        depthMm: depthMm ?? this.depthMm,
        boardThicknessMm: boardThicknessMm ?? this.boardThicknessMm,
        requiredTools: requiredTools ?? this.requiredTools,
        previewUrl: previewUrl ?? this.previewUrl,
        recommendedSpindleRpm:
            recommendedSpindleRpm ?? this.recommendedSpindleRpm,
        recommendedFeedRate: recommendedFeedRate ?? this.recommendedFeedRate,
      );
}
