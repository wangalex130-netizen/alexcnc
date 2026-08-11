/// 模型库 REST 接口响应模型（对齐 模型库接口文档.md /api/model-library/*）。

import 'library_item.dart';

/// 首页聚合：`/api/model-library/home`。
///
/// 一次返回焦点模型（heroModels，最多 6 个）、分类 Tab（categories）、
/// 以及按传入分页/筛选参数返回的模型网格（models 为分页对象）。
class ModelLibraryHome {
  final List<LibraryItem> heroModels;
  final List<String> categories;
  final List<LibraryItem> models;
  final int total;
  final int pageNo;
  final int pageSize;
  final int pages;

  const ModelLibraryHome({
    this.heroModels = const [],
    this.categories = const [],
    this.models = const [],
    this.total = 0,
    this.pageNo = 1,
    this.pageSize = 12,
    this.pages = 1,
  });

  factory ModelLibraryHome.fromJson(Map<String, dynamic> j) {
    final modelsObj = j['models'] as Map<String, dynamic>? ?? {};
    final list = (modelsObj['list'] as List? ?? [])
        .map((e) => LibraryItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return ModelLibraryHome(
      heroModels: (j['heroModels'] as List? ?? [])
          .map((e) => LibraryItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      categories: (j['categories'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
      models: list,
      total: (modelsObj['total'] as num? ?? 0).toInt(),
      pageNo: (modelsObj['pageNo'] as num? ?? 1).toInt(),
      pageSize: (modelsObj['pageSize'] as num? ?? 12).toInt(),
      pages: (modelsObj['pages'] as num? ?? 1).toInt(),
    );
  }
}

/// 模型分页列表：`/api/model-library/list`。
///
/// `data` 直接是分页对象（list/total/pageNo/pageSize/pages）。
class ModelLibraryPage {
  final List<LibraryItem> items;
  final int total;
  final int pageNo;
  final int pageSize;
  final int pages;

  const ModelLibraryPage({
    this.items = const [],
    this.total = 0,
    this.pageNo = 1,
    this.pageSize = 12,
    this.pages = 1,
  });

  factory ModelLibraryPage.fromJson(Map<String, dynamic> j) => ModelLibraryPage(
        items: (j['list'] as List? ?? [])
            .map((e) => LibraryItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] as num? ?? 0).toInt(),
        pageNo: (j['pageNo'] as num? ?? 1).toInt(),
        pageSize: (j['pageSize'] as num? ?? 12).toInt(),
        pages: (j['pages'] as num? ?? 1).toInt(),
      );
}
