import '../data/material_db.dart';
import '../models/library_item.dart';
import '../models/model_library.dart';
import '../models/push_log_entry.dart';
import '../models/sys_bit.dart';
import '../models/task_metadata.dart';
import 'cloud_service.dart';

/// In-memory cloud stand-in.
class MockCloudService implements CloudService {
  @override
  Future<List<MaterialSpec>> fetchMaterials() async {
    await Future.delayed(const Duration(milliseconds: 150));
    return materials;
  }

  @override
  Future<TaskMetadata?> getActiveTask() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return const TaskMetadata(
      id: 'task-001',
      name: '胡桃木杯垫',
      widthMm: 80,
      heightMm: 80,
      depthMm: 3,
      boardThicknessMm: 8,
      recommendedSpindleRpm: 12000,
      recommendedFeedRate: 600,
    );
  }

  @override
  Future<TaskMetadata?> getTaskById(String id) async {
    await Future.delayed(const Duration(milliseconds: 200));
    // Stand-in: synthesize task metadata for the selected model. The real
    // cloud returns the actual dimensions/material parameters uploaded from PC.
    // 对齐 Step 4 原稿 GlobalState：复古木雕花纹板 145×95 松木 3.0mm rpm10000 feed1500
    final isRetro = id == 'insp-hero' ||
        id.contains('retro') ||
        id.contains('wood') ||
        id.contains('复古');
    if (isRetro) {
      return TaskMetadata(
        id: id,
        name: '复古木雕花纹板',
        widthMm: 145,
        heightMm: 95,
        depthMm: 3,
        boardThicknessMm: 3,
        recommendedSpindleRpm: 10000,
        recommendedFeedRate: 1500,
        defaultMaterialKey: 'pine', // Step1 默认雕刻材料：松木
        defaultToolId: 't_flat_3175', // Step1 默认刀具：3.175 平底刀
        // 有序工序刀具：先粗雕（平底刀）后精雕（V 型刀），与物理刀兜解耦
        requiredTools: const [
          RequiredTool('t_flat_3175', '粗雕 / 轮廓'),
          RequiredTool('t_v60', '精雕 / 刻线'),
        ],
      );
    }
    final isAcrylic = id.contains('acrylic');
    final matKey = isAcrylic ? 'acrylic' : 'pine';
    return TaskMetadata(
      id: id,
      name: id.startsWith('insp') ? '灵感作品' : '我的工程包',
      widthMm: 90,
      heightMm: 90,
      depthMm: 3,
      boardThicknessMm: 8,
      recommendedSpindleRpm: isAcrylic ? 14000 : 12000,
      recommendedFeedRate: isAcrylic ? 800 : 1500,
      defaultMaterialKey: matKey,
      defaultToolId: matKey == 'acrylic' ? 't_o_single_3175' : 't_flat_3175',
      requiredTools: matKey == 'acrylic'
          ? const [
              RequiredTool('t_o_single_3175', '亚克力粗雕'),
              RequiredTool('t_v60', '精雕 / 刻线'),
            ]
          : const [
              RequiredTool('t_flat_3175', '粗雕 / 轮廓'),
              RequiredTool('t_v60', '精雕 / 刻线'),
            ],
    );
  }

  @override
  Future<List<LibraryItem>> getInspiration({int page = 0}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return const [
      LibraryItem(
        id: 'insp-hero',
        title: '复古几何木质杯垫套组',
        author: '官方精选',
        imageUrl:
            'https://images.unsplash.com/photo-1546554137-f86b9593a222?auto=format&fit=crop&w=600&q=80',
        isPublic: true,
        materialPreset: '黑胡桃木 (3mm)',
        category: '木作工艺',
        duration: '12分30秒',
        isHero: true,
        heroTag: '周末主推干货',
      ),
      LibraryItem(
        id: 'insp-1',
        title: '赛博朋克发光铭牌',
        author: 'NeoCraft',
        imageUrl:
            'https://images.unsplash.com/photo-1517055729424-69974240954b?auto=format&fit=crop&w=300&q=80',
        isPublic: true,
        materialPreset: '双色亚克力',
        category: '亚克力',
        duration: '8分10秒',
      ),
      LibraryItem(
        id: 'insp-2',
        title: 'Arduino 扩展板打样',
        author: 'PCB_Lab',
        imageUrl:
            'https://images.unsplash.com/photo-1592659762303-90081d34b277?auto=format&fit=crop&w=300&q=80',
        isPublic: true,
        materialPreset: '覆铜板 PCB',
        category: 'PCB 电路',
        duration: '15分02秒',
      ),
      LibraryItem(
        id: 'insp-3',
        title: '胡桃木手机支架',
        author: '木作老张',
        imageUrl:
            'https://images.unsplash.com/photo-1610701596007-11502861dcfa?auto=format&fit=crop&w=300&q=80',
        isPublic: true,
        materialPreset: '黑胡桃木',
        category: '木作工艺',
        duration: '20分40秒',
      ),
      LibraryItem(
        id: 'insp-4',
        title: '亚克力展示盒',
        author: 'AcrylicPro',
        imageUrl:
            'https://images.unsplash.com/photo-1620641788421-7a1c342ea42e?auto=format&fit=crop&w=300&q=80',
        isPublic: true,
        materialPreset: '透明亚克力',
        category: '亚克力',
        duration: '6分35秒',
      ),
      LibraryItem(
        id: 'insp-5',
        title: 'PCB 开发板夹具',
        author: 'Maker_X',
        imageUrl:
            'https://images.unsplash.com/photo-1518770660439-4636190af475?auto=format&fit=crop&w=300&q=80',
        isPublic: true,
        materialPreset: '覆铜板 PCB',
        category: 'PCB 电路',
        duration: '11分20秒',
      ),
    ];
  }

  @override
  Future<List<LibraryItem>> getMySpace() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return const [
      LibraryItem(
        id: 'mine-1',
        title: '定制化_父亲节底座_V2',
        author: 'me',
        isPublic: false,
        materialPreset: '松木板',
        syncTime: '今天 14:30 同步',
      ),
      LibraryItem(
        id: 'mine-2',
        title: '圆孔阵列_测试治具',
        author: 'me',
        isPublic: false,
        materialPreset: '亚克力',
        syncTime: '昨天 09:15 同步',
      ),
      // 成功加工记录（历史复用）
      LibraryItem(
        id: 'hist-1',
        title: '官方_几何木质杯垫',
        author: 'me',
        isPublic: false,
        materialPreset: '黑胡桃木',
        duration: '耗时 12分35秒',
        syncTime: '2026/07/20',
        isHistory: true,
      ),
    ];
  }

  @override
  Future<bool> deleteModel(String id) async {
    await Future.delayed(const Duration(milliseconds: 200));
    // Mock 下始终成功（真实删除由 RealCloudService → 云端执行）
    return true;
  }

  @override
  Future<void> pushDiagnostics(String log) async {
    await Future.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<bool> reportPushToken(
    String token, {
    String deviceId = '',
    String userId = '',
    String platform = 'android',
    bool notifyComplete = true,
    bool notifyAlert = true,
  }) async {
    await Future.delayed(const Duration(milliseconds: 100));
    // Mock 下视为上报成功（无真实云端，仅演练 App 侧流程）
    return true;
  }

  @override
  Future<List<PushLogEntry>> fetchPushLog() async {
    await Future.delayed(const Duration(milliseconds: 100));
    // Mock 下无事件源，返回空（本地通知消费端在 Mock 模式下不弹）
    return const [];
  }

  @override
  Future<List<SysBit>> fetchSysBits() async {
    // Mock 兜底：返回与本地官方刀库一致的子集，保证离线也能看。
    return const [
      SysBit(id: 5, type: 'End Mills', name: '1/8 in Flat Cutter', bitType: 'Flat Cutter', diameter: '1/8 in'),
      SysBit(id: 20, type: 'Ballnose', name: '1/8 in Ballnose', bitType: 'Ballnose', diameter: '1/8 in'),
      SysBit(id: 1, type: 'V Bits', name: '30 Deg 1/8 V-Bit', bitType: 'V', diameter: '1/8 in', angle: '30'),
      SysBit(id: 2, type: 'V Bits', name: '60 Deg 1/8 V-Bit', bitType: 'V', diameter: '1/8 in', angle: '60'),
      SysBit(id: 3, type: 'V Bits', name: '90 Deg 1/8 V-Bit', bitType: 'V', diameter: '1/8 in', angle: '90'),
    ];
  }

  // ===================== 模型库 5 接口（Mock 兜底） =====================

  @override
  Future<ModelLibraryHome> getModelLibraryHome(
      {int pageNo = 1,
      int pageSize = 12,
      String? keyword,
      String? category,
      String? tag,
      bool? hero,
      String sortBy = 'recommend'}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final all = await getInspiration();
    final heros = all.where((e) => e.isHero).toList();
    final cats = <String>{};
    for (final e in all) {
      if (e.category != null && e.category!.isNotEmpty) cats.add(e.category!);
    }
    return ModelLibraryHome(
        heroModels: heros, categories: ['全部', ...cats], models: all);
  }

  @override
  Future<ModelLibraryPage> getModelLibraryList(
      {int pageNo = 1,
      int pageSize = 12,
      String? keyword,
      String? category,
      String? tag,
      bool? hero,
      String sortBy = 'recommend'}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    var all = await getInspiration();
    final kw = keyword?.trim().toLowerCase() ?? '';
    if (kw.isNotEmpty) {
      all = all
          .where((e) =>
              e.title.toLowerCase().contains(kw) ||
              e.tags.any((t) => t.toLowerCase().contains(kw)))
          .toList();
    }
    if (category != null && category.isNotEmpty && category != 'all') {
      all = all.where((e) => e.category == category).toList();
    }
    final start = (pageNo - 1) * pageSize;
    final end = start + pageSize;
    final slice = all.sublist(start.clamp(0, all.length),
        end.clamp(0, all.length));
    return ModelLibraryPage(
      items: slice,
      pageNo: pageNo,
      pageSize: pageSize,
      total: all.length,
      pages: all.isEmpty ? 1 : ((all.length + pageSize - 1) ~/ pageSize),
    );
  }

  @override
  Future<LibraryItem?> getModelLibraryDetail(String id) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final all = await getInspiration();
    final base = all.firstWhere((e) => e.id == id, orElse: () => all.first);
    final isRetro = id.contains('retro') ||
        id.contains('复古') ||
        id.contains('wood');
    return base.copyWith(
      recommendedSpindleRpm: isRetro ? 10000 : 12000,
      recommendedFeedRate: isRetro ? 1500 : 600,
      widthMm: isRetro ? 145 : 90,
      heightMm: isRetro ? 95 : 90,
      depthMm: 3,
      gcodeStatus: 'sliced',
      requiredTools: const [
        RequiredTool('t_flat_3175', '粗雕 / 轮廓'),
        RequiredTool('t_v60', '精雕 / 刻线'),
      ],
    );
  }

  @override
  Future<List<String>> getModelLibraryCategories() async {
    await Future.delayed(const Duration(milliseconds: 150));
    return const ['全部', '木作工艺', '亚克力', 'PCB 电路'];
  }

  @override
  Future<List<String>> getModelLibraryTags() async {
    await Future.delayed(const Duration(milliseconds: 150));
    return const ['复古', '几何', '发光', 'PCB', '杯垫', '铭牌'];
  }
}
