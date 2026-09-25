import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../app/theme.dart';

/// 统一图片缓存管理器（工单十 §3）。
///
/// flutter_cache_manager 只支持「对象个数 + 过期天数」，不支持按字节封顶；
/// 按 800 个对象 ≈ 200MB 量级封顶（磁盘缓存上限定值的落地口径），30 天过期，
/// 「设置 → 清理缓存」可随时手动清空兜底。
class CncImageCacheManager extends CacheManager with ImageCacheManager {
  static final CncImageCacheManager instance = CncImageCacheManager._();

  CncImageCacheManager._()
      : super(const Config(
          'cncImageCache',
          stalePeriod: Duration(days: 30),
          maxNrOfCacheObjects: 800,
        ));
}

/// 统一网络图组件：磁盘缓存 + 150ms 渐现 + 令牌占位底色（深浅色自动跟随）。
class CncCachedImage extends StatelessWidget {
  const CncCachedImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
    this.fallback,
  });

  final String url;
  final BoxFit fit;

  /// 网格缩略图解码上限 600px（工单十 §3.2）；大图不传保持原分辨率。
  final int? memCacheWidth;

  /// 加载失败时的降级占位；缺省为令牌底色块。
  final WidgetBuilder? fallback;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: CncImageCacheManager.instance,
      fit: fit,
      memCacheWidth: memCacheWidth,
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: const Duration(milliseconds: 150),
      placeholder: (_, __) => Container(color: CncColors.panelAlt),
      errorWidget: (_, __, ___) =>
          fallback?.call(context) ?? Container(color: CncColors.panelAlt),
    );
  }
}
