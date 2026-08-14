import '../data/material_db.dart';
import '../models/library_item.dart';
import '../models/model_library.dart';
import '../models/task_metadata.dart';

/// Cloud boundary (Smart CNC Studio / 阿里云|AWS MQTT).
///
/// The App deliberately never downloads raw G-code. It only fetches task
/// metadata and a tiny render JSON (handled where the 2D preview lives). The
/// cloud pushes the actual sliced file straight to the MCU over LAN/MQTT.
abstract class CloudService {
  /// 材质参数主表（云端唯一真源，三端共用）。
  /// 实现应优先拉云端、失败回退本地缓存；App 仅展示/回显，不持有加工参数。
  Future<List<MaterialSpec>> fetchMaterials();

  Future<TaskMetadata?> getActiveTask();
  /// Fetch the task metadata for a specific library item (entered via wizard).
  Future<TaskMetadata?> getTaskById(String id);
  Future<List<LibraryItem>> getInspiration({int page = 0});
  Future<List<LibraryItem>> getMySpace();
  /// 删除「我的空间」里的模型/任务（电脑端上传的私有模型可下架）。
  Future<bool> deleteModel(String id);
  Future<void> pushDiagnostics(String log);

  // ---- 模型库 5 接口（docs/模型库接口文档.md）----
  Future<ModelLibraryHome> getModelLibraryHome(
      {int pageNo = 1,
      int pageSize = 12,
      String? keyword,
      String? category,
      String? tag,
      bool? hero,
      String sortBy = 'recommend'});
  Future<ModelLibraryPage> getModelLibraryList(
      {int pageNo = 1,
      int pageSize = 12,
      String? keyword,
      String? category,
      String? tag,
      bool? hero,
      String sortBy = 'recommend'});
  Future<LibraryItem?> getModelLibraryDetail(String id);
  Future<List<String>> getModelLibraryCategories();
  Future<List<String>> getModelLibraryTags();
}
