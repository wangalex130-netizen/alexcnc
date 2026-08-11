import '../models/library_item.dart';
import '../models/task_metadata.dart';
import '../models/model_library.dart';

/// Cloud boundary (Smart CNC Studio / 云端 MQTT).
///
/// 旧接口（任务元数据 / 我的空间 / 诊断）+ 模型库 REST 接口（/api/model-library/*，
/// 对齐 模型库接口文档.md）。App 默认走 Mock；在「联调设置」开启真实后端后打真实 REST，
/// 请求失败统一回退 Mock，保证无网 / 联调也能打开 App。
abstract class CloudService {
  // ---- 旧接口 ----
  Future<TaskMetadata?> getActiveTask();
  Future<TaskMetadata?> getTaskById(String id);
  Future<List<LibraryItem>> getInspiration({int page = 0});
  Future<List<LibraryItem>> getMySpace();
  Future<void> pushDiagnostics(String log);

  // ---- 模型库 REST 接口（5 个，对齐 模型库接口文档.md）----
  Future<ModelLibraryHome> getModelLibraryHome({
    int pageNo = 1,
    int pageSize = 12,
    String? keyword,
    String? category,
    String? tag,
    bool? hero,
    String sortBy = 'recommend',
  });
  Future<ModelLibraryPage> getModelLibraryList({
    int pageNo = 1,
    int pageSize = 12,
    String? keyword,
    String? category,
    String? tag,
    bool? hero,
    String sortBy = 'recommend',
  });
  Future<LibraryItem?> getModelLibraryDetail(String id);
  Future<List<String>> getModelLibraryCategories();
  Future<List<String>> getModelLibraryTags();
}
