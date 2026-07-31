import '../models/library_item.dart';
import '../models/task_metadata.dart';
import 'cloud_service.dart';

/// In-memory cloud stand-in.
class MockCloudService implements CloudService {
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
    final isAcrylic = id.contains('acrylic');
    return TaskMetadata(
      id: id,
      name: id.startsWith('insp') ? '灵感作品' : '我的工程包',
      widthMm: 90,
      heightMm: 90,
      depthMm: 3,
      boardThicknessMm: 8,
      recommendedSpindleRpm: isAcrylic ? 14000 : 12000,
      recommendedFeedRate: 600,
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
  Future<void> pushDiagnostics(String log) async {
    await Future.delayed(const Duration(milliseconds: 200));
  }
}
