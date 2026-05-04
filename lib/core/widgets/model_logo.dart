import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:screen_memo/core/utils/model_icon_utils.dart';
import 'package:screen_memo/features/ai/application/models_dev_catalog_service.dart';

/// 使用本地 SVG 素材的模型 / 提供商 Logo。
///
/// 元数据仍可用于辅助判断，但图标渲染始终走 [ModelIconUtils] 的本地资源匹配。
class ModelLogo extends StatelessWidget {
  const ModelLogo({
    super.key,
    this.modelId,
    this.metadata,
    this.size = 20,
    this.colorFilter,
    this.padding,
  });

  final String? modelId;
  final ModelsDevModelInfo? metadata;
  final double size;
  final ColorFilter? colorFilter;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final modelName = (modelId ?? '').trim().isNotEmpty
        ? modelId
        : ((metadata?.id.trim().isNotEmpty ?? false)
              ? metadata?.id
              : metadata?.name);
    return _LogoBox(
      assetPath: ModelIconUtils.getIconPath(modelName),
      size: size,
      colorFilter: colorFilter,
      padding: padding,
    );
  }
}

class ProviderLogo extends StatelessWidget {
  const ProviderLogo({
    super.key,
    this.providerType,
    this.providerName,
    this.baseUrl,
    this.providerId,
    this.size = 20,
    this.colorFilter,
    this.padding,
  });

  final String? providerType;
  final String? providerName;
  final String? baseUrl;
  final String? providerId;
  final double size;
  final ColorFilter? colorFilter;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final providerKey = _localProviderKey();
    return _LogoBox(
      assetPath: ModelIconUtils.getProviderIconPath(providerKey),
      size: size,
      colorFilter: colorFilter,
      padding: padding,
    );
  }

  String _localProviderKey() {
    final explicit = (providerId ?? '').trim();
    if (explicit.isNotEmpty) return explicit;

    final type = (providerType ?? '').trim();
    final lowerType = type.toLowerCase();
    if (lowerType.isNotEmpty && lowerType != 'custom') return lowerType;

    final byUrl = ModelsDevCatalogService.inferProviderIdFromUrl(baseUrl);
    if (byUrl.isNotEmpty) return byUrl;

    final name = (providerName ?? '').trim();
    if (name.isNotEmpty) return name;
    return type;
  }
}

class _LogoBox extends StatelessWidget {
  const _LogoBox({
    required this.assetPath,
    required this.size,
    this.colorFilter,
    this.padding,
  });

  final String assetPath;
  final double size;
  final ColorFilter? colorFilter;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final Widget child = SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      colorFilter: colorFilter,
    );
    if (padding == null) return child;
    return Padding(padding: padding!, child: child);
  }
}
