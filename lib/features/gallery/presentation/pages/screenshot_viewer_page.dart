import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;
import 'package:screen_memo/l10n/app_localizations.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:screen_memo/core/theme/app_theme.dart';
import 'package:screen_memo/core/widgets/ui_dialog.dart';
import 'package:screen_memo/models/screenshot_record.dart';
import 'package:screen_memo/models/app_info.dart';
import 'package:screen_memo/features/capture/application/screenshot_service.dart';
import 'package:screen_memo/core/widgets/ui_components.dart';
import 'package:screen_memo/core/logging/flutter_logger.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/features/nsfw/application/nsfw_preference_service.dart';
import 'package:screen_memo/features/apps/application/app_selection_service.dart';
import 'package:screen_memo/features/apps/presentation/widgets/lazy_app_icon.dart';
import 'package:screen_memo/features/gallery/presentation/widgets/ai_meta_sheet.dart';
import 'package:gal/gal.dart';

/// 截图查看器页面
class ScreenshotViewerPage extends StatefulWidget {
  const ScreenshotViewerPage({super.key});

  @override
  State<ScreenshotViewerPage> createState() => _ScreenshotViewerPageState();
}

class _ScreenshotViewerPageState extends State<ScreenshotViewerPage> {
  static const MethodChannel _platform = MethodChannel(
    'com.fqyw.screen_memo/accessibility',
  );
  List<ScreenshotRecord> _screenshots = <ScreenshotRecord>[];
  int _currentIndex = 0;
  String _appName = 'Unknown';
  AppInfo _appInfo = _unknownAppInfo();
  PageController? _pageController;
  bool _showAppBar = true;
  bool _initialized = false;
  bool _singleMode = false; // 单图模式（对话内联图：强制1/1）

  // 动态页 AI 图片标签/描述（可选）
  Map<String, dynamic>? _aiStructured;
  final Map<String, List<String>> _aiTagsByFile = <String, List<String>>{};
  final Map<String, String> _aiDescByFile = <String, String>{};
  final Map<String, String> _aiDescRangeByFile = <String, String>{};

  // 已揭示的 NSFW 图片（本会话内）
  final Set<int> _revealedIds = <int>{};
  final Set<String> _revealedPaths = <String>{};
  // 隐私模式（从设置读取）
  bool _privacyMode = true;

  // 移除调试日志

  static AppInfo _unknownAppInfo({
    String packageName = 'unknown',
    String appName = 'Unknown',
  }) {
    return AppInfo(
      packageName: packageName,
      appName: appName,
      icon: null,
      version: '',
      isSystemApp: false,
    );
  }

  bool get _hasValidCurrent =>
      _screenshots.isNotEmpty &&
      _currentIndex >= 0 &&
      _currentIndex < _screenshots.length;

  ScreenshotRecord? get _currentScreenshotOrNull =>
      _hasValidCurrent ? _screenshots[_currentIndex] : null;

  String _displayPackageFor(ScreenshotRecord screenshot) {
    final String recordPackage = screenshot.appPackageName.trim();
    if (recordPackage.isNotEmpty && recordPackage.toLowerCase() != 'unknown') {
      return recordPackage;
    }
    return _appInfo.packageName.trim();
  }

  String _displayAppNameFor(ScreenshotRecord screenshot) {
    final String packageName = _displayPackageFor(screenshot);
    final String recordName = screenshot.appName.trim();
    if (_isUsefulAppName(recordName, packageName)) {
      return recordName;
    }

    final bool appInfoMatchesCurrent =
        packageName.isNotEmpty && _appInfo.packageName.trim() == packageName;
    if (appInfoMatchesCurrent) {
      final String infoName = _appInfo.appName.trim();
      if (_isUsefulAppName(infoName, packageName)) return infoName;

      final String routeName = _appName.trim();
      if (_isUsefulAppName(routeName, packageName)) return routeName;
    }

    if (recordName.isNotEmpty) return recordName;
    if (packageName.isNotEmpty) return packageName;
    return 'Unknown';
  }

  bool _isUsefulAppName(String name, String packageName) {
    final String value = name.trim();
    if (value.isEmpty) return false;
    final String lower = value.toLowerCase();
    if (lower == 'unknown') return false;
    if (packageName.trim().isNotEmpty && value == packageName.trim()) {
      return false;
    }
    return true;
  }

  Uint8List? _initialIconForPackage(String packageName) {
    final String currentPackage = packageName.trim();
    if (currentPackage.isEmpty) return null;
    if (_appInfo.packageName.trim() != currentPackage) return null;
    final icon = _appInfo.icon;
    if (icon == null || icon.isEmpty) return null;
    return icon;
  }

  int _coerceIndex(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  int _clampIndex(int index, int length) {
    if (length <= 0) return 0;
    if (index < 0) return 0;
    if (index >= length) return length - 1;
    return index;
  }

  Map<String, dynamic>? _coerceRouteArgs(Object? rawArgs) {
    if (rawArgs is! Map) return null;
    final args = <String, dynamic>{};
    for (final entry in rawArgs.entries) {
      final key = entry.key;
      if (key is String) {
        args[key] = entry.value;
      }
    }
    return args;
  }

  void _setEmptyViewerState() {
    _screenshots = <ScreenshotRecord>[];
    _currentIndex = 0;
    _appName = 'Unknown';
    _appInfo = _unknownAppInfo();
    _singleMode = false;
  }

  bool _initFromRouteArgs(Object? rawArgs) {
    final args = _coerceRouteArgs(rawArgs);
    if (args == null) {
      _setEmptyViewerState();
      return false;
    }

    final rawPaths = args['paths'];
    if (rawPaths is List) {
      final paths = rawPaths
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
      if (paths.isNotEmpty) {
        _singleMode = args['singleMode'] is bool
            ? args['singleMode'] as bool
            : true;
        final requestedIndex = _clampIndex(
          _coerceIndex(args['initialIndex']),
          paths.length,
        );
        final selectedPaths = _singleMode
            ? <String>[paths[requestedIndex]]
            : paths;
        _screenshots = selectedPaths
            .map(
              (p) => ScreenshotRecord(
                id: null,
                appPackageName: 'unknown',
                appName: 'Unknown',
                filePath: p,
                captureTime: DateTime.now(),
                fileSize: 0,
              ),
            )
            .toList();
        _currentIndex = _singleMode ? 0 : requestedIndex;
        _appName = (args['appName'] as String?)?.trim().isNotEmpty == true
            ? (args['appName'] as String).trim()
            : 'Unknown';
        _appInfo = args['appInfo'] is AppInfo
            ? args['appInfo'] as AppInfo
            : _unknownAppInfo(appName: _appName);
        // 后台补全元数据（不阻塞UI）
        // ignore: unawaited_futures
        _hydrateRecordsAndAppInfo(
          _singleMode ? <String>[_screenshots[0].filePath] : paths,
        );
        return true;
      }
    }

    final rawScreenshots = args['screenshots'];
    if (rawScreenshots is! List) {
      _setEmptyViewerState();
      return false;
    }

    _screenshots = rawScreenshots.whereType<ScreenshotRecord>().toList(
      growable: true,
    );
    if (_screenshots.isEmpty) {
      _setEmptyViewerState();
      return false;
    }

    _singleMode = false;
    _currentIndex = _clampIndex(
      _coerceIndex(args['initialIndex']),
      _screenshots.length,
    );
    final firstScreenshot = _screenshots[_currentIndex];
    final appInfoArg = args['appInfo'];
    _appInfo = appInfoArg is AppInfo
        ? appInfoArg
        : _unknownAppInfo(
            packageName: firstScreenshot.appPackageName,
            appName: firstScreenshot.appName,
          );
    final rawAppName = args['appName'];
    _appName = rawAppName is String && rawAppName.trim().isNotEmpty
        ? rawAppName.trim()
        : _appInfo.appName;
    return true;
  }

  @override
  void initState() {
    super.initState();
    // Android：通过原生方法通道隐藏状态栏（仅顶部）
    if (Platform.isAndroid) {
      _platform.invokeMethod('hideStatusBar');
    }
  }

  Future<void> _openCurrentLink() async {
    final current = _currentScreenshotOrNull;
    if (current == null) return;
    final url = current.pageUrl;
    if (url == null || url.isEmpty) return;
    try {
      // 记录点击打开链接的日志（Flutter 与原生）
      // ignore: unawaited_futures
      FlutterLogger.info('UI.查看器-打开链接 链接=$url');
      // ignore: unawaited_futures
      FlutterLogger.nativeInfo('UI', '查看器打开链接：$url');
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _showLinkDialog() async {
    final current = _currentScreenshotOrNull;
    if (current == null) return;
    final url = current.pageUrl;
    if (url == null || url.isEmpty) return;
    await showUIDialog<void>(
      context: context,
      title: AppLocalizations.of(context).linkTitle,
      content: SelectableText(url, textAlign: TextAlign.center),
      barrierDismissible: true,
      actions: [
        UIDialogAction<void>(
          text: AppLocalizations.of(context).actionCopy,
          style: UIDialogActionStyle.primary,
          closeOnPress: true,
          onPressed: (ctx) async {
            try {
              await Clipboard.setData(ClipboardData(text: url));
              // ignore: unawaited_futures
              FlutterLogger.info('UI.查看器-复制链接 成功');
              // ignore: unawaited_futures
              FlutterLogger.nativeInfo('UI', '查看器复制链接成功');
              if (mounted) {
                UINotifier.success(
                  context,
                  AppLocalizations.of(context).copySuccess,
                );
              }
            } catch (e) {
              // ignore: unawaited_futures
              FlutterLogger.error('UI.查看器-复制链接 失败: $e');
              // ignore: unawaited_futures
              FlutterLogger.nativeError('UI', '查看器复制链接失败：$e');
              if (mounted) {
                UINotifier.error(
                  context,
                  AppLocalizations.of(context).copyFailed,
                );
              }
            }
          },
        ),
        UIDialogAction<void>(
          text: AppLocalizations.of(context).openLink,
          style: UIDialogActionStyle.normal,
          closeOnPress: true,
          onPressed: (ctx) async {
            await _openCurrentLink();
          },
        ),
        UIDialogAction<void>(
          text: AppLocalizations.of(context).dialogCancel,
          style: UIDialogActionStyle.normal,
          closeOnPress: true,
        ),
      ],
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_initialized) return;

    // 获取路由参数（仅初始化一次，避免后续依赖变化导致索引重置）
    final rawArgs = ModalRoute.of(context)?.settings.arguments;
    final args = _coerceRouteArgs(rawArgs);
    final hasValidData = _initFromRouteArgs(rawArgs);
    _pageController = PageController(initialPage: _currentIndex);
    _initialized = true;
    if (!hasValidData || args == null) return;

    // 尝试解析来自动态页的结构化 JSON（用于图片标签/描述展示）
    _initAiMeta(args);
    // 若未携带结构化 JSON（或部分缺失），则从主库 ai_image_meta 回填，用于全局复用
    // ignore: unawaited_futures
    _loadAiMetaFromDb();

    // 预加载 NSFW 规则与手动标记（不阻塞UI）
    // ignore: unawaited_futures
    NsfwPreferenceService.instance.ensureRulesLoaded();
    final ids = _screenshots
        .where((s) => s.id != null)
        .map((s) => s.id!)
        .toList();
    if (ids.isNotEmpty) {
      // ignore: unawaited_futures
      NsfwPreferenceService.instance.preloadManualFlags(
        appPackageName: _appInfo.packageName,
        screenshotIds: ids,
      );
    }
    final paths = _screenshots
        .map((s) => s.filePath.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (paths.isNotEmpty) {
      // ignore: unawaited_futures
      NsfwPreferenceService.instance.preloadAiNsfwFlags(filePaths: paths);
      // ignore: unawaited_futures
      NsfwPreferenceService.instance.preloadSegmentNsfwFlags(filePaths: paths);
    }
    // 同步隐私模式
    // ignore: unawaited_futures
    _loadPrivacyMode();

    // 预热当前与相邻图片，降低首帧解码卡顿
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _precacheAround(_currentIndex);
    });
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx >= 0 ? normalized.substring(idx + 1) : normalized;
  }

  void _initAiMeta(Map<String, dynamic> args) {
    _aiStructured = null;
    _aiTagsByFile.clear();
    _aiDescByFile.clear();
    _aiDescRangeByFile.clear();

    try {
      final dynamic raw = args['aiStructuredJson'];
      if (raw is String && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _aiStructured = Map<String, dynamic>.from(decoded);
        }
      } else if (raw is Map) {
        _aiStructured = Map<String, dynamic>.from(raw);
      }
    } catch (_) {
      _aiStructured = null;
    }

    final sj = _aiStructured;
    if (sj == null || _screenshots.isEmpty) return;

    // 1) image_tags -> file -> tags[]
    try {
      final dynamic rawTags = sj['image_tags'];
      if (rawTags is List) {
        for (final e in rawTags) {
          if (e is! Map) continue;
          final m = Map<String, dynamic>.from(e);
          final String rawFile = (m['file'] ?? '').toString().trim();
          if (rawFile.isEmpty) continue;
          final String file = _basename(rawFile);
          final dynamic raw = m['tags'];
          final List<String> tags = <String>[];
          if (raw is List) {
            for (final t in raw) {
              final v = t.toString().trim();
              if (v.isNotEmpty) tags.add(v);
            }
          } else if (raw is String) {
            tags.addAll(
              raw
                  .split(RegExp(r'[，,;；\s]+'))
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty),
            );
          }
          if (tags.isNotEmpty) {
            _aiTagsByFile[file] = tags;
          }
        }
      }
    } catch (_) {}

    // 2) image_descriptions -> map to each file in [from..to]
    try {
      final Map<String, int> indexByFile = <String, int>{};
      final List<String> files = <String>[];
      for (int i = 0; i < _screenshots.length; i++) {
        final String f = _basename(_screenshots[i].filePath);
        files.add(f);
        indexByFile.putIfAbsent(f, () => i);
      }

      final dynamic rawDescs = sj['image_descriptions'];
      if (rawDescs is List) {
        for (final e in rawDescs) {
          if (e is! Map) continue;
          final m = Map<String, dynamic>.from(e);
          final String from = (m['from_file'] ?? m['from'] ?? m['start'] ?? '')
              .toString()
              .trim();
          final String to = (m['to_file'] ?? m['to'] ?? m['end'] ?? '')
              .toString()
              .trim();
          final String desc = (m['description'] ?? m['desc'] ?? '')
              .toString()
              .trim();
          if (desc.isEmpty) continue;

          final String a = from.isNotEmpty ? from : to;
          final String b = to.isNotEmpty ? to : from;
          if (a.isEmpty || b.isEmpty) continue;

          final int? ia = indexByFile[a];
          final int? ib = indexByFile[b];
          if (ia == null || ib == null) continue;

          int start = ia;
          int end = ib;
          if (start > end) {
            final tmp = start;
            start = end;
            end = tmp;
          }

          final String rangeLabel = (a != b) ? '$a-$b' : a;
          for (int i = start; i <= end && i < files.length; i++) {
            final f = files[i];
            _aiDescByFile[f] = desc;
            _aiDescRangeByFile[f] = rangeLabel;
          }
        }
      }
    } catch (_) {}

    // 3) described_images -> fallback per-file description (legacy structured JSON)
    try {
      final dynamic rawDescribed = sj['described_images'];
      if (rawDescribed is List) {
        for (final e in rawDescribed) {
          if (e is! Map) continue;
          final m = Map<String, dynamic>.from(e);
          final String rawFile = (m['file'] ?? '').toString().trim();
          if (rawFile.isEmpty) continue;
          final String file = _basename(rawFile);
          final String desc =
              (m['summary'] ?? m['summary_md'] ?? m['desc'] ?? '')
                  .toString()
                  .trim();
          if (desc.isEmpty) continue;
          if ((_aiDescByFile[file] ?? '').trim().isNotEmpty) continue;
          _aiDescByFile[file] = desc;
          _aiDescRangeByFile[file] = file;
        }
      }
    } catch (_) {}
  }

  Future<void> _loadAiMetaFromDb() async {
    if (_screenshots.isEmpty) return;
    try {
      final paths = _screenshots
          .map((s) => s.filePath)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
      if (paths.isEmpty) return;

      final map = await ScreenshotDatabase.instance.getAiImageMetaByFilePaths(
        paths,
      );
      if (!mounted || map.isEmpty) return;

      bool changed = false;

      for (final s in _screenshots) {
        final String fileName = _basename(s.filePath);
        final row = map[s.filePath];
        if (row == null) continue;

        // 1) tags_json -> tags[]
        if (!_aiTagsByFile.containsKey(fileName) ||
            (_aiTagsByFile[fileName]?.isEmpty ?? true)) {
          final raw = (row['tags_json'] as String?)?.trim();
          if (raw != null && raw.isNotEmpty) {
            final List<String> tags = <String>[];
            try {
              final decoded = jsonDecode(raw);
              if (decoded is List) {
                for (final t in decoded) {
                  final v = t.toString().trim();
                  if (v.isNotEmpty) tags.add(v);
                }
              } else if (decoded is String) {
                tags.addAll(
                  decoded
                      .split(RegExp(r'[，,;；\s]+'))
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty),
                );
              }
            } catch (_) {
              tags.addAll(
                raw
                    .split(RegExp(r'[，,;；\s]+'))
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty),
              );
            }
            if (tags.isNotEmpty) {
              _aiTagsByFile[fileName] = tags;
              changed = true;
            }
          }
        }

        // 2) description / description_range
        if ((_aiDescByFile[fileName] ?? '').trim().isEmpty) {
          final desc = (row['description'] as String?)?.trim() ?? '';
          if (desc.isNotEmpty) {
            _aiDescByFile[fileName] = desc;
            final range = (row['description_range'] as String?)?.trim();
            _aiDescRangeByFile[fileName] = (range != null && range.isNotEmpty)
                ? range
                : fileName;
            changed = true;
          }
        }
      }

      if (changed && mounted) {
        setState(() {});
      }
    } catch (_) {}
  }

  Widget _buildAiMetaBar(BuildContext context) {
    final current = _currentScreenshotOrNull;
    if (current == null) return const SizedBox.shrink();
    final String file = _basename(current.filePath);
    final List<String> tags = _aiTagsByFile[file] ?? const <String>[];
    final String desc = (_aiDescByFile[file] ?? '').trim();
    final String range = (_aiDescRangeByFile[file] ?? file).trim();
    if (tags.isEmpty && desc.isEmpty) return const SizedBox.shrink();

    final String preview = desc.isNotEmpty
        ? desc.replaceAll(RegExp(r'\s+'), ' ').trim()
        : tags.join(' · ');

    return Positioned(
      left: 12,
      right: 12,
      bottom: 10,
      child: SafeArea(
        top: false,
        child: Material(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => AiMetaSheet.show(
              context,
              filePath: current.filePath,
              fallbackTags: tags,
              fallbackDescription: desc,
              fallbackRange: range,
              fallbackOcrText: current.ocrText,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  const Text(
                    'AI',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: Colors.white70,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 保留给后续恢复 AI 图片元数据总览入口。
  // ignore: unused_element
  Future<void> _showAiMetaOverview() async {
    if (_screenshots.isEmpty) return;

    final List<_AiMetaDescGroup> descGroups = <_AiMetaDescGroup>[];
    final List<_AiMetaTagLine> tagLines = <_AiMetaTagLine>[];

    final Map<String, int> firstIndexByRange = <String, int>{};
    final Map<String, String> descByRange = <String, String>{};

    for (int i = 0; i < _screenshots.length; i++) {
      final String file = _basename(_screenshots[i].filePath);

      final String desc = (_aiDescByFile[file] ?? '').trim();
      if (desc.isNotEmpty) {
        final String range = (_aiDescRangeByFile[file] ?? file).trim();
        final String key = range.isNotEmpty ? range : file;
        firstIndexByRange.putIfAbsent(key, () => i);
        if (!descByRange.containsKey(key)) {
          descByRange[key] = desc;
        } else if (descByRange[key] != desc) {
          final String altKey = '$key#${i + 1}';
          firstIndexByRange.putIfAbsent(altKey, () => i);
          descByRange.putIfAbsent(altKey, () => desc);
        }
      }

      final List<String> tags = _aiTagsByFile[file] ?? const <String>[];
      if (tags.isNotEmpty) {
        tagLines.add(_AiMetaTagLine(index: i, file: file, tags: tags));
      }
    }

    for (final e in descByRange.entries) {
      descGroups.add(
        _AiMetaDescGroup(
          index: firstIndexByRange[e.key] ?? 0,
          label: e.key,
          description: e.value,
        ),
      );
    }
    descGroups.sort((a, b) => a.index.compareTo(b.index));
    tagLines.sort((a, b) => a.index.compareTo(b.index));

    if (descGroups.isEmpty && tagLines.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final l10n = AppLocalizations.of(ctx);
        String buildCopyText() {
          final List<String> parts = <String>[];
          parts.add('AI');

          if (descGroups.isNotEmpty) {
            parts.add(l10n.aiImageDescriptionsTitle);
            parts.add(
              descGroups
                  .map((g) => '${g.label}:\n${g.description}')
                  .join('\n\n'),
            );
          }

          if (tagLines.isNotEmpty) {
            parts.add(l10n.aiImageTagsTitle);
            parts.add(
              tagLines
                  .map((t) => '${t.file}: ${t.tags.join(' · ')}')
                  .join('\n'),
            );
          }

          return parts.where((e) => e.trim().isNotEmpty).join('\n\n').trim();
        }

        return DraggableScrollableSheet(
          initialChildSize: 0.72,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, ctrl) {
            return UISheetSurface(
              child: Column(
                children: [
                  const SizedBox(height: AppTheme.spacing3),
                  const UISheetHandle(),
                  const SizedBox(height: AppTheme.spacing3),
                  Expanded(
                    child: ListView(
                      controller: ctrl,
                      padding: const EdgeInsets.fromLTRB(
                        AppTheme.spacing4,
                        0,
                        AppTheme.spacing4,
                        AppTheme.spacing6,
                      ),
                      children: [
                        Row(
                          children: [
                            const Text(
                              'AI',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${descGroups.length} ${l10n.aiImageDescriptionsTitle} · ${tagLines.length} ${l10n.aiImageTagsTitle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(ctx).textTheme.bodySmall
                                    ?.copyWith(color: AppTheme.mutedForeground),
                              ),
                            ),
                            IconButton(
                              tooltip: l10n.copyResultsTooltip,
                              icon: const Icon(
                                Icons.copy_all_outlined,
                                size: 18,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () async {
                                final String text = buildCopyText();
                                if (text.trim().isEmpty) return;
                                try {
                                  await Clipboard.setData(
                                    ClipboardData(text: text),
                                  );
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(l10n.copySuccess)),
                                  );
                                } catch (_) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(l10n.copyFailed)),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (descGroups.isNotEmpty) ...[
                          Text(
                            l10n.aiImageDescriptionsTitle,
                            style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...descGroups.map(
                            (g) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: SelectableText(
                                '${g.label}:\n${g.description}',
                                style: Theme.of(ctx).textTheme.bodyMedium,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        if (tagLines.isNotEmpty) ...[
                          Text(
                            l10n.aiImageTagsTitle,
                            style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...tagLines.map(
                            (t) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: SelectableText(
                                '${t.file}: ${t.tags.join(' · ')}',
                                style: Theme.of(ctx).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    // Android：恢复状态栏
    if (Platform.isAndroid) {
      _platform.invokeMethod('showStatusBar').catchError((_) {});
    }
    _pageController?.dispose();
    super.dispose();
  }

  void _toggleAppBar() {
    setState(() {
      _showAppBar = !_showAppBar;
    });
  }

  /// 后台补全记录与应用信息
  Future<void> _hydrateRecordsAndAppInfo(List<String> paths) async {
    try {
      // ignore: unawaited_futures
      FlutterLogger.info('UI.Viewer：初始化开始 数量=${paths.length}');
      final recs = await Future.wait(
        paths.map(
          (p) => ScreenshotDatabase.instance
              .getScreenshotByPath(p)
              .catchError((_) => null),
        ),
      );
      bool changed = false;
      final List<ScreenshotRecord> hydrated = List<ScreenshotRecord>.from(
        _screenshots,
      );
      for (int i = 0; i < hydrated.length && i < recs.length; i++) {
        final r = recs[i];
        if (r != null) {
          hydrated[i] = r;
          changed = true;
        }
      }
      // 尝试基于当前项更新 AppInfo
      AppInfo? app;
      try {
        if (hydrated.isEmpty) return;
        final head =
            hydrated[(_currentIndex >= 0 && _currentIndex < hydrated.length)
                ? _currentIndex
                : 0];
        final pkg = head.appPackageName;
        final cachedApp = await AppSelectionService.instance.getCachedAppInfo(
          pkg,
        );
        final apps = await AppSelectionService.instance.getAllInstalledApps();
        app = apps.firstWhere(
          (a) => a.packageName == pkg,
          orElse: () =>
              cachedApp ??
              AppInfo(
                packageName: pkg,
                appName: head.appName,
                icon: null,
                version: '',
                isSystemApp: false,
              ),
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        if (changed) _screenshots = hydrated;
        if (app != null) {
          _appInfo = app;
          _appName = app.appName;
        }
      });
      // ignore: unawaited_futures
      FlutterLogger.info('UI.Viewer：初始化完成 有变化=${changed ? '1' : '0'}');
    } catch (_) {}
  }

  /// 预热当前与相邻图片
  Future<void> _precacheAround(int index) async {
    if (!mounted || _screenshots.isEmpty) return;
    final List<int> candidates = <int>{
      index,
      index - 1,
      index + 1,
    }.where((i) => i >= 0 && i < _screenshots.length).toList();
    for (final i in candidates) {
      final f = File(_screenshots[i].filePath);
      try {
        // ignore: unawaited_futures
        FlutterLogger.debug('UI.Viewer：预缓存 索引=$i');
        await precacheImage(FileImage(f), context);
      } catch (_) {}
    }
  }

  Future<void> _deleteCurrentImage() async {
    final screenshot = _currentScreenshotOrNull;
    if (screenshot == null) return;

    final confirmed = await showUIDialog<bool>(
      context: context,
      title: AppLocalizations.of(context).confirmDeleteTitle,
      message: AppLocalizations.of(context).confirmDeleteMessage,
      actions: [
        UIDialogAction<bool>(
          text: AppLocalizations.of(context).dialogCancel,
          result: false,
        ),
        UIDialogAction<bool>(
          text: AppLocalizations.of(context).actionDelete,
          style: UIDialogActionStyle.destructive,
          result: true,
        ),
      ],
      barrierDismissible: false,
    );

    if (confirmed == true && screenshot.id != null) {
      // 记录UI删除操作日志
      // ignore: unawaited_futures
      FlutterLogger.info(
        'UI.查看器-删除当前-发起 id=${screenshot.id} 包=${screenshot.appPackageName} 路径=${screenshot.filePath}',
      );
      // ignore: unawaited_futures
      FlutterLogger.nativeInfo('UI', '查看器删除开始 id=${screenshot.id}');
      try {
        final success = await ScreenshotService.instance.deleteScreenshot(
          screenshot.id!,
          screenshot.appPackageName,
          filePath: screenshot.filePath,
        );
        if (success) {
          // ignore: unawaited_futures
          FlutterLogger.info('UI.查看器-删除当前-成功 id=${screenshot.id}');
          // ignore: unawaited_futures
          FlutterLogger.nativeInfo('UI', '查看器删除成功 id=${screenshot.id}');
          var shouldCloseViewer = false;
          setState(() {
            _screenshots.removeAt(_currentIndex);

            // 调整当前索引
            if (_screenshots.isEmpty) {
              shouldCloseViewer = true;
              return;
            } else if (_currentIndex >= _screenshots.length) {
              _currentIndex = _screenshots.length - 1;
            }
          });

          if (!mounted) return;
          if (shouldCloseViewer) {
            // 不要在 setState 内执行导航，避免页面短暂进入空数据黑屏状态。
            Navigator.of(context).maybePop();
            return;
          }

          if (mounted) {
            UINotifier.success(
              context,
              AppLocalizations.of(context).screenshotDeletedToast,
            );
          }
        } else {
          // ignore: unawaited_futures
          FlutterLogger.warn('UI.查看器-删除当前-失败 id=${screenshot.id}');
          // ignore: unawaited_futures
          FlutterLogger.nativeWarn('UI', '查看器删除失败 id=${screenshot.id}');
          if (mounted) {
            UINotifier.error(
              context,
              AppLocalizations.of(context).deleteFailed,
            );
          }
        }
      } catch (e) {
        // ignore: unawaited_futures
        FlutterLogger.error('UI.查看器-删除当前-异常: $e');
        // ignore: unawaited_futures
        FlutterLogger.nativeError('UI', '查看器删除异常: $e');
        if (mounted) {
          UINotifier.error(
            context,
            AppLocalizations.of(context).deleteFailedWithError(e.toString()),
          );
        }
      }
    }
  }

  void _showImageInfo() {
    final screenshot = _currentScreenshotOrNull;
    if (screenshot == null) return;

    showUIDialog<void>(
      context: context,
      title: AppLocalizations.of(context).imageInfoTitle,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow(
            AppLocalizations.of(context).labelAppName,
            screenshot.appName,
          ),
          _buildInfoRow(
            AppLocalizations.of(context).labelCaptureTime,
            _formatDateTime(screenshot.captureTime),
          ),
          _buildInfoRow(
            AppLocalizations.of(context).labelFilePath,
            screenshot.filePath,
          ),
          if (screenshot.pageUrl != null && screenshot.pageUrl!.isNotEmpty)
            _buildInfoRow(
              AppLocalizations.of(context).labelPageLink,
              screenshot.pageUrl!,
            ),
          if (screenshot.fileSize > 0)
            _buildInfoRow(
              AppLocalizations.of(context).labelFileSize,
              _formatFileSize(screenshot.fileSize),
            ),
        ],
      ),
      actions: [UIDialogAction(text: AppLocalizations.of(context).dialogOk)],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final labelColor = onSurface.withValues(alpha: 0.7);
    final valueColor = onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: TextStyle(fontWeight: FontWeight.w500, color: labelColor),
            ),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: valueColor)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pageController = _pageController;
    final current = _currentScreenshotOrNull;
    if (pageController == null || current == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).maybePop();
        }
      });
      return Scaffold(
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? Theme.of(context).scaffoldBackgroundColor
            : Colors.black,
        body: const SizedBox.expand(),
      );
    }
    final String currentPackageName = _displayPackageFor(current);
    final String currentAppName = _displayAppNameFor(current);
    final Uint8List? currentInitialIcon = _initialIconForPackage(
      currentPackageName,
    );

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? Theme.of(context).scaffoldBackgroundColor
          : Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showAppBar
          ? AppBar(
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? Theme.of(
                      context,
                    ).scaffoldBackgroundColor.withValues(alpha: 0.85)
                  : Colors.black.withValues(alpha: 0.7),
              elevation: 0,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 应用图标
                  Container(
                    width: 24,
                    height: 24,
                    margin: const EdgeInsets.only(right: 8),
                    child: LazyAppIcon(
                      packageName: currentPackageName,
                      initialIcon: currentInitialIcon,
                      size: 24,
                      fallback: const Icon(
                        Icons.android,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  // 应用名称和计数
                  Flexible(
                    child: Text(
                      _singleMode
                          ? '$currentAppName (1/1)'
                          : '$currentAppName (${_currentIndex + 1}/${_screenshots.length})',
                      style: const TextStyle(color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                IconButton(
                  icon: const Icon(Icons.download_outlined),
                  onPressed: _saveCurrentToGallery,
                  tooltip: AppLocalizations.of(context).saveImageTooltip,
                ),
                IconButton(
                  icon: const Icon(Icons.info_outline),
                  onPressed: _showImageInfo,
                  tooltip: AppLocalizations.of(context).imageInfoTooltip,
                ),
                if ((current.pageUrl ?? '').isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.link),
                    onPressed: _showLinkDialog,
                    tooltip: AppLocalizations.of(context).linkTitle,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _deleteCurrentImage,
                  tooltip: AppLocalizations.of(context).deleteImageTooltip,
                ),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: _toggleAppBar,
        onLongPress: _showNsfwMenu,
        child: Stack(
          children: [
            PhotoViewGallery.builder(
              scrollPhysics: const BouncingScrollPhysics(),
              builder: (BuildContext context, int index) {
                if (index < 0 || index >= _screenshots.length) {
                  return PhotoViewGalleryPageOptions.customChild(
                    child: Center(
                      child: Text(
                        AppLocalizations.of(context).imageLoadFailed,
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ),
                  );
                }
                final screenshot = _screenshots[index];
                final file = File(screenshot.filePath);

                return PhotoViewGalleryPageOptions(
                  imageProvider: FileImage(file),
                  initialScale: PhotoViewComputedScale.contained,
                  minScale: PhotoViewComputedScale.contained, // 最小缩放为原图比例，不能再缩小
                  maxScale: PhotoViewComputedScale.covered * 4.0,
                  errorBuilder: (context, error, stackTrace) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.broken_image,
                            color: Colors.white54,
                            size: 64,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            AppLocalizations.of(context).imageLoadFailed,
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
              itemCount: _singleMode ? 1 : _screenshots.length,
              loadingBuilder: (context, event) => const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
              backgroundDecoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Theme.of(context).scaffoldBackgroundColor
                    : Colors.black,
              ),
              pageController: pageController,
              onPageChanged: _singleMode
                  ? null
                  : (index) {
                      setState(() {
                        _currentIndex = index;
                      });
                      _precacheAround(index);
                    },
            ),

            // NSFW 遮罩（规则 + 手动标记 + 自动识别聚合；用户点“显示”后本会话内记忆）
            if (_hasValidCurrent) ...[
              Builder(
                builder: (context) {
                  final s = _currentScreenshotOrNull;
                  if (s == null) return const SizedBox.shrink();
                  final id = s.id;
                  final fileName = _basename(s.filePath);
                  final aiTags = _aiTagsByFile[fileName] ?? const <String>[];
                  final bool aiNsfw = aiTags.any(
                    (t) => t.toString().trim().toLowerCase() == 'nsfw',
                  );
                  final bool revealed =
                      (id != null && _revealedIds.contains(id)) ||
                      (id == null && _revealedPaths.contains(s.filePath));
                  final masked =
                      _privacyMode &&
                      (aiNsfw ||
                          NsfwPreferenceService.instance.shouldMaskCached(s)) &&
                      !revealed;
                  if (!masked) return const SizedBox.shrink();
                  return Stack(
                    children: [
                      // 背景模糊 + 变暗层（手势穿透）
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: true,
                          child: BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                      ),
                      // 中央文案 + “显示”按钮（仅按钮可点击）
                      Positioned.fill(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.visibility_off_rounded,
                                color: Colors.white70,
                                size: 28,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                AppLocalizations.of(context).nsfwWarningTitle,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                AppLocalizations.of(
                                  context,
                                ).nsfwWarningSubtitle,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: 86,
                                height: 34,
                                child: ElevatedButton(
                                  onPressed: () {
                                    setState(() {
                                      if (id != null) {
                                        _revealedIds.add(id);
                                      } else {
                                        _revealedPaths.add(s.filePath);
                                      }
                                    });
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white.withValues(
                                      alpha: 0.9,
                                    ),
                                    foregroundColor: Colors.black87,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        AppTheme.radiusMd,
                                      ),
                                    ),
                                    padding: EdgeInsets.zero,
                                    elevation: 0,
                                    textStyle: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  child: Text(
                                    AppLocalizations.of(context).show,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],

            // AI 图片标签/描述（全局入口，避免遮挡大图）
            _buildAiMetaBar(context),

            // 按需求：大图查看页不显示顶部链接遮罩，仅保留右上角链接图标
            if (Theme.of(context).brightness == Brightness.dark)
              IgnorePointer(
                child: Container(color: Colors.black.withValues(alpha: 0.5)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveCurrentToGallery() async {
    final current = _currentScreenshotOrNull;
    if (current == null) return;
    final l10n = AppLocalizations.of(context);
    final path = current.filePath;
    try {
      bool has = false;
      try {
        has = await Gal.hasAccess(toAlbum: true);
      } catch (_) {}
      if (!has) {
        try {
          await Gal.requestAccess(toAlbum: true);
        } catch (_) {
          if (!mounted) return;
          UINotifier.error(context, l10n.requestGalleryPermissionFailed);
          return;
        }
      }
      await Gal.putImage(path);
      if (!mounted) return;
      UINotifier.success(context, l10n.saveImageSuccess);
    } on GalException catch (_) {
      if (!mounted) return;
      UINotifier.error(context, l10n.saveImageFailed);
    } catch (_) {
      if (!mounted) return;
      UINotifier.error(context, l10n.saveImageFailed);
    }
  }

  Future<void> _loadPrivacyMode() async {
    try {
      final enabled = await AppSelectionService.instance
          .getPrivacyModeEnabled();
      if (mounted) {
        setState(() {
          _privacyMode = enabled;
        });
      }
    } catch (_) {}
  }

  String? _nsfwRuleHostFromUrl(String? url) {
    final String raw = (url ?? '').trim();
    if (raw.isEmpty) return null;
    try {
      final (host, _) = NsfwPreferenceService.instance.normalizeAndValidate(
        raw,
      );
      return host;
    } catch (_) {
      return null;
    }
  }

  Future<void> _showNsfwMenu() async {
    final s = _currentScreenshotOrNull;
    if (s == null) return;
    final l10n = AppLocalizations.of(context);
    final id = s.id;
    final String? nsfwRuleHost = _nsfwRuleHostFromUrl(s.pageUrl);
    if (id == null && nsfwRuleHost == null) return;
    final bool canManualMark = id != null;
    final bool isFlagged =
        canManualMark &&
        NsfwPreferenceService.instance.isManuallyFlaggedCached(
          screenshotId: id,
          appPackageName: s.appPackageName,
        );
    final actionMark = !isFlagged;
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return UISheetSurface(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppTheme.spacing3),
              const UISheetHandle(),
              const SizedBox(height: AppTheme.spacing2),
              if (canManualMark)
                ListTile(
                  leading: Icon(
                    actionMark ? Icons.visibility_off : Icons.visibility,
                  ),
                  title: Text(
                    actionMark ? l10n.manualMarkNsfw : l10n.manualUnmarkNsfw,
                  ),
                  onTap: () =>
                      Navigator.of(ctx).pop(actionMark ? 'mark' : 'unmark'),
                ),
              if (nsfwRuleHost != null)
                ListTile(
                  leading: const Icon(Icons.public_off_outlined),
                  title: Text(l10n.addCurrentSiteToNsfw),
                  subtitle: Text(nsfwRuleHost),
                  onTap: () => Navigator.of(ctx).pop('add_domain'),
                ),
              const SizedBox(height: AppTheme.spacing2),
            ],
          ),
        );
      },
    );
    if (result == null) return;
    if (result == 'add_domain') {
      final String? host = nsfwRuleHost;
      if (host == null) return;
      final ok = await NsfwPreferenceService.instance.addRule(host);
      if (!mounted) return;
      if (ok) {
        setState(() {
          if (id != null) {
            _revealedIds.remove(id);
          } else {
            _revealedPaths.remove(s.filePath);
          }
        });
        UINotifier.success(context, l10n.ruleAddedToast);
      } else {
        UINotifier.error(context, l10n.operationFailed);
      }
      return;
    }
    if (id == null) return;
    final ok = await NsfwPreferenceService.instance.setManualFlag(
      screenshotId: id,
      appPackageName: s.appPackageName,
      flag: result == 'mark',
    );
    if (!mounted) return;
    if (ok) {
      setState(() {
        if (result == 'mark') {
          _revealedIds.remove(id); // 标记后恢复遮罩
        } else {
          _revealedIds.remove(id);
        }
      });
      UINotifier.success(
        context,
        result == 'mark' ? l10n.manualMarkSuccess : l10n.manualUnmarkSuccess,
      );
    } else {
      UINotifier.error(context, l10n.manualMarkFailed);
    }
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}/${dateTime.month.toString().padLeft(2, '0')}/${dateTime.day.toString().padLeft(2, '0')} '
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}:${dateTime.second.toString().padLeft(2, '0')}';
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '${bytes}B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    } else {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
  }
}

class _AiMetaDescGroup {
  const _AiMetaDescGroup({
    required this.index,
    required this.label,
    required this.description,
  });

  final int index;
  final String label;
  final String description;
}

class _AiMetaTagLine {
  const _AiMetaTagLine({
    required this.index,
    required this.file,
    required this.tags,
  });

  final int index;
  final String file;
  final List<String> tags;
}
