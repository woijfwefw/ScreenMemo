import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:screen_memo/core/logging/flutter_logger.dart';
import 'package:screen_memo/core/theme/app_theme.dart';
import 'package:screen_memo/models/screenshot_record.dart';
import 'package:screen_memo/features/nsfw/application/nsfw_preference_service.dart';
import 'package:screen_memo/features/nsfw/presentation/widgets/nsfw_guard.dart';
import 'package:screen_memo/features/timeline/presentation/widgets/timeline_jump_overlay.dart';

/// 统一的截图图片显示组件
///
/// 自动处理：
/// - 深色模式遮罩
/// - 隐私模式（NSFW）遮罩
/// - 图片加载和错误处理
///
/// 使用此组件可确保所有截图显示保持一致的样式和行为
class ScreenshotImageWidget extends StatefulWidget {
  /// 图片文件
  final File file;

  /// Optional override for the underlying ImageProvider (useful for perf probes).
  final ImageProvider? imageProvider;

  /// 是否启用隐私模式
  final bool privacyMode;

  /// 额外的 NSFW 遮罩（例如来自 AI 的 nsfw tag）
  final bool extraNsfwMask;

  /// 页面链接（用于判断是否为 NSFW）- 已废弃，使用 screenshot 参数
  final String? pageUrl;

  /// 截图记录（用于准确判断 NSFW）
  final ScreenshotRecord? screenshot;

  /// 图片宽度
  final double? width;

  /// 图片高度
  final double? height;

  /// 图片适配方式
  final BoxFit fit;

  /// 圆角
  final BorderRadius? borderRadius;

  /// 点击回调
  final VoidCallback? onTap;

  /// NSFW 显示回调（点击"显示"按钮时）
  final VoidCallback? onReveal;

  /// 是否显示 NSFW 的"显示"按钮
  final bool showNsfwButton;

  /// 目标缩略图宽度（用于性能优化）
  final int? targetWidth;

  /// 错误占位文本
  final String? errorText;

  /// 是否显示“时间线跳转”按钮（默认关闭）
  final bool showTimelineJumpButton;

  const ScreenshotImageWidget({
    super.key,
    required this.file,
    this.imageProvider,
    this.privacyMode = true,
    this.extraNsfwMask = false,
    this.pageUrl,
    this.screenshot,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.onTap,
    this.onReveal,
    this.showNsfwButton = true,
    this.targetWidth,
    this.errorText,
    this.showTimelineJumpButton = false,
  });

  @override
  State<ScreenshotImageWidget> createState() => _ScreenshotImageWidgetState();
}

class _ScreenshotImageWidgetState extends State<ScreenshotImageWidget> {
  bool _revealed = false;

  @override
  void didUpdateWidget(covariant ScreenshotImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 动态展开图会先用 file_path 建小图，再分批补全 ScreenshotRecord / pageUrl /
    // AI 标记。补全会触发父组件重建；如果这里因元数据变化重置 reveal，
    // 用户点“显示”后会被下一批补全立刻复遮，看起来像点击无反应。
    // 因此 reveal 状态只跟图片身份（file path）绑定。
    if (oldWidget.file.path != widget.file.path) {
      _revealed = false;
    }
  }

  void _revealNsfw() {
    final callback = widget.onReveal;
    unawaited(
      FlutterLogger.nativeInfo(
        'UI',
        'NSFW缩略图点击显示 path=${widget.file.path} externalReveal=${callback != null}',
      ).catchError((_) {}),
    );
    if (callback != null) {
      callback();
      return;
    }
    setState(() => _revealed = true);
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    // 优先使用 screenshot 参数进行准确判断，否则回退到旧的 URL 判断方式
    final bool nsfwMasked =
        widget.privacyMode &&
        !_revealed &&
        (widget.extraNsfwMask ||
            (widget.screenshot != null
                ? NsfwPreferenceService.instance.shouldMaskCached(
                    widget.screenshot!,
                  )
                : NsfwPreferenceService.instance.shouldMaskUrlCached(
                    pageUrl: widget.pageUrl,
                  )));

    Widget base = _buildImage(context, isDark);

    final List<Widget> layers = <Widget>[base];

    // NSFW 遮罩（位于图片之上）
    if (nsfwMasked) {
      layers.add(
        Positioned.fill(
          child: NsfwBackdropOverlay(
            borderRadius: widget.borderRadius,
            onReveal: _revealNsfw,
            showButton: widget.showNsfwButton,
          ),
        ),
      );
    }

    // 时间线跳转按钮（位于最上层）
    if (widget.showTimelineJumpButton) {
      layers.add(TimelineJumpOverlay(filePath: widget.file.path));
    }

    Widget result = layers.length == 1 ? base : Stack(children: layers);

    // 允许在遮罩状态下点击（例如进入查看器再选择“显示”）。
    final bool allowWholeImageTap =
        widget.onTap != null && (!nsfwMasked || !widget.showNsfwButton);
    if (allowWholeImageTap) {
      result = GestureDetector(onTap: widget.onTap, child: result);
    }

    // 添加圆角裁剪
    if (widget.borderRadius != null) {
      result = ClipRRect(borderRadius: widget.borderRadius!, child: result);
    }

    return result;
  }

  /// 构建图片
  Widget _buildImage(BuildContext context, bool isDark) {
    final ImageProvider provider =
        widget.imageProvider ??
        (widget.targetWidth != null
            ? ResizeImage(FileImage(widget.file), width: widget.targetWidth!)
            : FileImage(widget.file));

    final baseImage = Image(
      image: provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => _buildErrorWidget(context),
    );

    // 深色模式下添加黑色遮罩
    if (isDark) {
      return ColorFiltered(
        colorFilter: ColorFilter.mode(
          Colors.black.withValues(alpha: 0.5),
          BlendMode.darken,
        ),
        child: baseImage,
      );
    }

    return baseImage;
  }

  /// 构建错误占位
  Widget _buildErrorWidget(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: widget.borderRadius,
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image, size: 32, color: AppTheme.mutedForeground),
          if (widget.errorText != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.errorText!,
              style: TextStyle(color: AppTheme.mutedForeground, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
