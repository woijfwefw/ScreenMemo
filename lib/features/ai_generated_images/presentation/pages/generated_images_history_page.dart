import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:screen_memo/core/theme/app_theme.dart';
import 'package:screen_memo/core/widgets/ui_components.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/l10n/app_localizations.dart';
import 'package:screen_memo/models/app_info.dart';

class GeneratedImagesHistoryPage extends StatefulWidget {
  const GeneratedImagesHistoryPage({super.key});

  @override
  State<GeneratedImagesHistoryPage> createState() =>
      _GeneratedImagesHistoryPageState();
}

class _GeneratedImagesHistoryPageState
    extends State<GeneratedImagesHistoryPage> {
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  int _totalCount = 0;
  int _totalBytes = 0;

  static const int _pageSize = 80;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients ||
        _loading ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    final ScrollPosition pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 480) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      if (mounted) {
        setState(() {
          _loading = true;
          _loadingMore = false;
          _hasMore = true;
          _offset = 0;
          _items.clear();
          _totalCount = 0;
          _totalBytes = 0;
        });
      }
    } else {
      if (_loadingMore || !_hasMore) return;
      if (mounted) setState(() => _loadingMore = true);
    }

    try {
      if (reset) {
        await _loadStats();
      }
      final List<Map<String, dynamic>> rows = await ScreenshotDatabase.instance
          .listAiGeneratedImages(limit: _pageSize, offset: _offset);
      if (!mounted) return;
      setState(() {
        _items.addAll(rows);
        _offset += rows.length;
        _hasMore = rows.length >= _pageSize;
      });
    } catch (_) {
      if (mounted) {
        UINotifier.error(
          context,
          AppLocalizations.of(context).aiGeneratedHistoryLoadFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _refresh() => _load(reset: true);

  Future<void> _loadStats() async {
    final Map<String, int> stats = await ScreenshotDatabase.instance
        .getAiGeneratedImagesStorageStats();
    if (!mounted) return;
    setState(() {
      _totalCount = stats['count'] ?? 0;
      _totalBytes = stats['bytes'] ?? 0;
    });
  }

  String _basename(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final int idx = normalized.lastIndexOf('/');
    return idx >= 0 ? normalized.substring(idx + 1) : normalized;
  }

  int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '';
    return DateFormat(
      'yyyy-MM-dd HH:mm',
    ).format(DateTime.fromMillisecondsSinceEpoch(ms).toLocal());
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
    const int kb = 1024;
    const int mb = 1024 * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  String _formatCompactBytes(int bytes) {
    if (bytes <= 0) return '0MB';
    const int mb = 1024 * 1024;
    const int gb = 1024 * mb;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)}GB';
    return '${(bytes / mb).toStringAsFixed(2)}MB';
  }

  String _statsText(AppLocalizations l10n) {
    return '${l10n.imagesCountLabel(_totalCount)}${_formatCompactBytes(_totalBytes)}';
  }

  Future<void> _openPreview(Map<String, dynamic> item) async {
    final String path = (item['file_path'] as String?)?.trim() ?? '';
    if (path.isEmpty || !await File(path).exists()) {
      if (mounted) {
        UINotifier.error(
          context,
          AppLocalizations.of(context).aiGeneratedImageUnavailable,
        );
      }
      return;
    }
    if (!mounted) return;
    final String title = AppLocalizations.of(context).aiGeneratedDefaultTitle;
    await Navigator.of(context).pushNamed(
      '/screenshot_viewer',
      arguments: {
        'paths': <String>[path],
        'initialIndex': 0,
        'appName': title,
        'appInfo': AppInfo(
          packageName: 'generated.image',
          appName: title,
          icon: null,
          version: '',
          isSystemApp: false,
        ),
        'multiApp': false,
        'singleMode': true,
      },
    );
  }

  Future<void> _share(Map<String, dynamic> item) async {
    final String path = (item['file_path'] as String?)?.trim() ?? '';
    if (path.isEmpty || !await File(path).exists()) {
      if (mounted) {
        UINotifier.error(
          context,
          AppLocalizations.of(context).aiGeneratedImageUnavailable,
        );
      }
      return;
    }
    if (!mounted) return;
    final String shareText = AppLocalizations.of(context).aiGeneratedShareText;
    try {
      await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(path)], text: shareText),
      );
    } catch (_) {
      if (mounted) {
        UINotifier.error(context, AppLocalizations.of(context).logShareFailed);
      }
    }
  }

  Future<void> _copyPrompt(Map<String, dynamic> item) async {
    final String prompt = (item['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) {
      if (mounted) {
        UINotifier.error(context, AppLocalizations.of(context).copyFailed);
      }
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: prompt));
      if (mounted) {
        UINotifier.success(context, AppLocalizations.of(context).copySuccess);
      }
    } catch (_) {
      if (mounted) {
        UINotifier.error(context, AppLocalizations.of(context).copyFailed);
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final int id = _toInt(item['id']);
    if (id <= 0) return;
    final bool ok =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context).aiGeneratedDeleteTitle),
            content: Text(
              AppLocalizations.of(context).aiGeneratedDeleteMessage,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(AppLocalizations.of(context).dialogCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(
                  AppLocalizations.of(context).actionDelete,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    final String path = (item['file_path'] as String?)?.trim() ?? '';
    try {
      await ScreenshotDatabase.instance.softDeleteAiGeneratedImage(id);
      if (path.isNotEmpty) {
        final File file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
      if (!mounted) return;
      setState(() {
        _items.removeWhere((row) => _toInt(row['id']) == id);
        _offset = _items.length;
        _totalCount = (_totalCount - 1).clamp(0, 1 << 31).toInt();
      });
      unawaited(_loadStats());
      UINotifier.success(
        context,
        AppLocalizations.of(context).aiGeneratedImageDeleted,
      );
    } catch (_) {
      if (mounted) {
        UINotifier.error(context, AppLocalizations.of(context).deleteFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aiGeneratedImagesHistoryTitle),
        actions: [
          IconButton(
            tooltip: l10n.actionRefresh,
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: AppTheme.spacing2),
              child: Text(
                _statsText(l10n),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppTheme.spacing6),
                children: [
                  const SizedBox(height: AppTheme.spacing8),
                  Icon(
                    Icons.image_not_supported_outlined,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: AppTheme.spacing3),
                  Text(
                    AppLocalizations.of(context).aiGeneratedHistoryEmptyTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacing2),
                  Text(
                    AppLocalizations.of(context).aiGeneratedHistoryEmptyDesc,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            : ListView.separated(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacing4,
                  AppTheme.spacing3,
                  AppTheme.spacing4,
                  AppTheme.spacing4,
                ),
                itemCount: _items.length + (_loadingMore ? 1 : 0),
                separatorBuilder: (context, index) =>
                    const SizedBox(height: AppTheme.spacing3),
                itemBuilder: (context, index) {
                  if (index >= _items.length) {
                    return const Padding(
                      padding: EdgeInsets.all(AppTheme.spacing4),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return _GeneratedImageHistoryTile(
                    item: _items[index],
                    basename: _basename,
                    formatDate: _formatDate,
                    formatBytes: _formatBytes,
                    onOpen: () => _openPreview(_items[index]),
                    onCopyPrompt: () => _copyPrompt(_items[index]),
                    onShare: () => _share(_items[index]),
                    onDelete: () => _delete(_items[index]),
                  );
                },
              ),
      ),
    );
  }
}

class _GeneratedImageHistoryTile extends StatelessWidget {
  const _GeneratedImageHistoryTile({
    required this.item,
    required this.basename,
    required this.formatDate,
    required this.formatBytes,
    required this.onOpen,
    required this.onCopyPrompt,
    required this.onShare,
    required this.onDelete,
  });

  final Map<String, dynamic> item;
  final String Function(String path) basename;
  final String Function(int ms) formatDate;
  final String Function(int bytes) formatBytes;
  final VoidCallback onOpen;
  final VoidCallback onCopyPrompt;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final String path = (item['file_path'] as String?)?.trim() ?? '';
    final String prompt = (item['prompt'] as String?)?.trim() ?? '';
    final String model = (item['model'] as String?)?.trim() ?? '';
    final String size = (item['size'] as String?)?.trim() ?? '';
    final String quality = (item['quality'] as String?)?.trim() ?? '';
    final String format = (item['output_format'] as String?)?.trim() ?? '';
    final int createdAt = _toInt(item['created_at']);
    final File file = File(path);
    final bool exists = path.isNotEmpty && file.existsSync();
    final int bytes = exists ? file.lengthSync() : 0;
    final String fileName = basename(path);
    final String meta = <String>[
      if (model.isNotEmpty) model,
      if (size.isNotEmpty) size,
      if (quality.isNotEmpty) quality,
      if (format.isNotEmpty) format,
      if (bytes > 0) formatBytes(bytes),
      if (createdAt > 0) formatDate(createdAt),
    ].join(' · ');
    final AppLocalizations l10n = AppLocalizations.of(context);

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: cs.outline.withValues(alpha: 0.16)),
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: exists ? onOpen : null,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ColoredBox(
                  color: cs.surfaceContainerHighest,
                  child: exists
                      ? Image.file(file, fit: BoxFit.cover)
                      : Center(
                          child: Icon(
                            Icons.image_outlined,
                            size: 42,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spacing3,
                AppTheme.spacing3,
                AppTheme.spacing2,
                AppTheme.spacing3,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          fileName.isEmpty
                              ? l10n.aiGeneratedDefaultTitle
                              : fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppTheme.spacing2),
                      _GeneratedImageIconButton(
                        tooltip: l10n.aiGeneratedCopyPrompt,
                        onPressed: prompt.isEmpty ? null : onCopyPrompt,
                        icon: Icons.copy_outlined,
                      ),
                      _GeneratedImageIconButton(
                        tooltip: l10n.actionShare,
                        onPressed: exists ? onShare : null,
                        icon: Icons.ios_share_outlined,
                      ),
                      _GeneratedImageIconButton(
                        tooltip: l10n.actionDelete,
                        onPressed: onDelete,
                        icon: Icons.delete_outline,
                        color: cs.error,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    prompt.isEmpty ? l10n.aiGeneratedNoPromptStored : prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.28,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.82),
                        height: 1.2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GeneratedImageIconButton extends StatelessWidget {
  const _GeneratedImageIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.color,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: color),
    );
  }
}
