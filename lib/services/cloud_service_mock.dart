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
  Future<List<LibraryItem>> getInspiration({int page = 0}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return List.generate(
      12,
      (i) => LibraryItem(
        id: 'insp-$i',
        title: '灵感作品 $i',
        author: 'user${i % 5}',
        isPublic: true,
        materialPreset: i.isEven ? '胡桃木' : '亚克力',
      ),
    );
  }

  @override
  Future<List<LibraryItem>> getMySpace() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return List.generate(
      6,
      (i) => LibraryItem(
        id: 'mine-$i',
        title: '我的工程包 $i',
        author: 'me',
        isPublic: false,
        materialPreset: '椴木',
      ),
    );
  }

  @override
  Future<void> pushDiagnostics(String log) async {
    await Future.delayed(const Duration(milliseconds: 200));
  }
}
