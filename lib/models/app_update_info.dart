/// 更新检查结果（PC 工程师《APP 手动检查更新接口》，2026-09-10）。
///
/// 接口：`POST {cloudBaseUrl}/api/app/updates/check`
///
/// 请求体：`{app_key | name, version, build_number}`
/// 响应体：`{schema_version, update_available, latest_version,
///           latest_build_number, release_notes, download_url}`
///
/// 同一接口服务三类目标：`android`（本 App）/ `camera`（摄像头）/ `screen`（屏幕）。
/// 服务端按「客户端上报的当前 version / build_number」与后台配置比对，得出
/// `update_available`；只有**存在新版本且后台已填下载地址**时才为 true。
///
/// 参数非法时接口返回 HTTP 400（`INVALID_REQUEST`），此处按「检查失败」处理。
library;

class AppUpdateInfo {
  /// 响应结构版本，当前固定为 1。已解析备查（UI 暂未使用）。
  final int schemaVersion;

  /// 是否存在可下载的新版本。
  final bool updateAvailable;

  /// 后台配置的最新版本号；未找到对应应用时回显请求中的当前版本号。
  final String latestVersion;

  /// 后台最新构建号；未找到对应应用时回显请求中的当前构建号。
  /// 已解析备查（「版本相同比构建号」的判定由服务端完成，UI 未直接使用）。
  final int latestBuildNumber;

  /// 更新说明；无需更新时为空字符串。
  final String releaseNotes;

  /// 安装包下载地址；无需更新时为空字符串。
  final String downloadUrl;

  const AppUpdateInfo({
    this.schemaVersion = 1,
    this.updateAvailable = false,
    this.latestVersion = '',
    this.latestBuildNumber = 0,
    this.releaseNotes = '',
    this.downloadUrl = '',
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> j) {
    int asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      return int.tryParse(v.toString()) ?? 0;
    }

    return AppUpdateInfo(
      schemaVersion: asInt(j['schema_version']),
      updateAvailable: j['update_available'] == true,
      latestVersion: (j['latest_version'] ?? '').toString(),
      latestBuildNumber: asInt(j['latest_build_number']),
      releaseNotes: (j['release_notes'] ?? '').toString(),
      downloadUrl: (j['download_url'] ?? '').toString(),
    );
  }

  @override
  String toString() =>
      'AppUpdateInfo(available: $updateAvailable, latest: $latestVersion'
      '+$latestBuildNumber, url: ${downloadUrl.isEmpty ? "-" : "有"})';
}

/// 更新检查的应用标识（对应接口的 `app_key`）。
///
/// 取值与接口文档一致，**不可随意改名**（服务端按此匹配）。
enum AppUpdateTarget {
  /// Android 客户端（本 App）。
  android('android'),

  /// 摄像头固件。
  camera('camera'),

  /// 屏幕固件。
  screen('screen');

  /// 接口 `app_key` 取值 —— **与接口文档字面量一致，不可改名**。
  /// （接口另有 `name` 参数，可选值 `Android` / `摄像头` / `屏幕`；
  /// 因 `app_key` 优先级更高且已足够，故不冗余保存 `name`。）
  final String appKey;

  const AppUpdateTarget(this.appKey);
}
