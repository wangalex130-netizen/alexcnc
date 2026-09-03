import '../data/material_db.dart';
import '../models/library_item.dart';
import '../models/model_library.dart';
import '../models/push_log_entry.dart';
import '../models/sys_bit.dart';
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

  /// 上报推送 token 与推送偏好（App 侧推送占位实现，P8）。
  ///
  /// - [token]：本机推送通道标识。当前为 App 生成的占位 token；
  ///   后端接入正式推送通道（FCM / 极光 / 友盟等）后替换 SDK 返回的
  ///   registrationId，本接口签名不变。
  /// - [deviceId]：绑定的机器唯一码（云端按机器路由推送目标）。
  /// - [platform]：'android' | 'ios'。
  /// - [notifyComplete]/[notifyAlert]：用户在「我的」页的推送偏好。
  ///
  /// 返回 true = 云端已接受；false / 异常 = 未注册成功（调用方静默）。
  Future<bool> reportPushToken(
    String token, {
    String deviceId,
    String userId = '',
    String platform,
    bool notifyComplete,
    bool notifyAlert,
  });

  /// 拉取云端推送发送记录（GET /api/v1/push/log，最新在前，最多 50 条）。
  ///
  /// App 本地通知消费端用它做增量水位轮询：找到比「上次已读水位」更新的
  /// 本机事件→弹本地通知。真实厂商聚合通道接入后，本接口契约不变（通道
  /// 换成 FCM/厂商，但发送记录仍落 push/log），可无缝复用。
  Future<List<PushLogEntry>> fetchPushLog();

  /// 系统内置刀头列表（GET /api/bit/sys/list，公开接口无需登录）。
  ///
  /// 云端是官方刀头**全集**（V Bits / End Mills / Ballnose…）；
  /// 本机可用的是子集（见 `SysBit.isLocalSupported`，与本地 5 把官方刀
  /// 按系统表名称匹配）。失败返回空列表（调用方回退/提示）。
  Future<List<SysBit>> fetchSysBits();
}
