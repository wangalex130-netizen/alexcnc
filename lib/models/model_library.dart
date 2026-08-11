import 'library_item.dart';

/// 模型库首页聚合（/api/model-library/home）。
///
/// 后端打包上测试环境后，字段以软件工程师的接口文档为准；这里做了多键名
/// 兼容（heroModels/heros/hero、models/list/records/items），Mock 与真后端都能解析。
class ModelLibraryHome {
  final List<LibraryItem> heroModels; // 焦点大图（主推）
  final List<String> categories; // 分类标签（接口权威来源）
  final List<LibraryItem> models; // 首屏模型列表

  const ModelLibraryHome({
    this.heroModels = const [],
    this.categories = const [],
    this.models = const [],
  });

  factory ModelLibraryHome.fromJson(Map<String, dynamic> j) {
    List<LibraryItem> parseList(dynamic v) => (v as List? ?? [])
        .map((e) => LibraryItem.fromJson(e as Map<String, dynamic>))
        .toList();
    List<String> parseCats(dynamic v) =>
        (v as List? ?? []).map((e) => e.toString()).toList();
    return ModelLibraryHome(
      heroModels: parseList(j['heroModels'] ?? j['heros'] ?? j['hero']),
      categories: parseCats(j['categories'] ?? j['categoryList']),
      models: parseList(
          j['models'] ?? j['list'] ?? j['records'] ?? j['items']),
    );
  }
}

/// 模型库分页列表（/api/model-library/list）。
class ModelLibraryPage {
  final List<LibraryItem> items;
  final int pageNo;
  final int pageSize;
  final int total;
  final int pages;

  const ModelLibraryPage({
    this.items = const [],
    this.pageNo = 1,
    this.pageSize = 12,
    this.total = 0,
    this.pages = 1,
  });

  factory ModelLibraryPage.fromJson(Map<String, dynamic> j) {
    List<LibraryItem> parseList(dynamic v) => (v as List? ?? [])
        .map((e) => LibraryItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return ModelLibraryPage(
      items: parseList(
          j['list'] ?? j['records'] ?? j['items'] ?? j['models']),
      pageNo: (j['pageNo'] as num? ?? 1).toInt(),
      pageSize: (j['pageSize'] as num? ?? 12).toInt(),
      total: (j['total'] as num? ?? 0).toInt(),
      pages: (j['pages'] as num? ?? 1).toInt(),
    );
  }
}
