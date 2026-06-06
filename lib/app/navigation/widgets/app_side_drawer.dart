import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_memo/l10n/app_localizations.dart';
import 'package:screen_memo/core/theme/theme_service.dart';
import 'package:screen_memo/features/ai_providers/presentation/pages/provider_list_page.dart';
import 'package:screen_memo/features/ai_chat/presentation/pages/prompt_manager_page.dart';
import 'package:screen_memo/features/ai_chat/presentation/pages/ai_settings_page.dart';
import 'package:screen_memo/core/theme/app_theme.dart';
import 'package:screen_memo/features/ai/application/ai_settings_service.dart';
import 'package:screen_memo/core/widgets/model_logo.dart';
import 'package:screen_memo/core/widgets/ui_components.dart';
import 'package:screen_memo/core/widgets/ui_dialog.dart';
import 'package:screen_memo/core/logging/flutter_logger.dart';
import 'package:screen_memo/app/navigation/navigation_service.dart';

/// 侧边栏：简洁清爽，复用设置页面样式
class AppSideDrawer extends StatefulWidget {
  final ThemeService? themeService;

  const AppSideDrawer({super.key, this.themeService});

  @override
  State<AppSideDrawer> createState() => _AppSideDrawerState();
}

class _AppSideDrawerState extends State<AppSideDrawer> {
  final Map<String, bool> _conversationExpansionByCid = <String, bool>{};
  Future<List<Object>>? _conversationListFuture;
  StreamSubscription<String>? _ctxChangedSub;

  @override
  void initState() {
    super.initState();
    _refreshConversationListFuture();
    _ctxChangedSub = AISettingsService.instance.onContextChanged.listen((ctx) {
      if (!mounted) return;
      if (ctx == 'chat' ||
          ctx == 'chat:deleted' ||
          ctx == 'chat:cleared' ||
          ctx == 'chat:history' ||
          ctx.startsWith('chat:history:')) {
        _refreshConversationList();
      }
    });
  }

  Future<List<Object>> _loadConversationListData() async {
    final Future<List<Map<String, dynamic>>> rowsFuture = AISettingsService
        .instance
        .listAiConversations(includeSubagents: true);
    final Future<String> activeFuture = AISettingsService.instance
        .getActiveConversationCid();
    return <Object>[await rowsFuture, await activeFuture];
  }

  void _refreshConversationListFuture() {
    _conversationListFuture = _loadConversationListData();
  }

  void _refreshConversationList() {
    setState(_refreshConversationListFuture);
  }

  @override
  void dispose() {
    _ctxChangedSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Drawer(
      backgroundColor: theme.scaffoldBackgroundColor,
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const SizedBox(height: AppTheme.spacing2),
            // 动态
            _buildMenuItem(
              context: context,
              icon: Icons.interests_outlined,
              title: t.segmentStatusTitle,
              isFirst: true,
              onTap: () {
                Navigator.of(context).pop();
                NavigationService.instance.openSegmentStatus();
              },
            ),
            // 提供商
            _buildMenuItem(
              context: context,
              icon: Icons.hub_outlined,
              title: t.providersTitle,
              isFirst: false,
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => ProviderListPage()));
              },
            ),
            // 提示词管理
            _buildMenuItem(
              context: context,
              icon: Icons.tips_and_updates_outlined,
              title: t.promptManagerTitle,
              isFirst: false,
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => PromptManagerPage()));
              },
            ),
            // —— 对话分割 + 会话列表 ——
            const SizedBox(height: AppTheme.spacing2),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacing3,
                vertical: AppTheme.spacing2,
              ),
              child: Text(
                t.conversationsSectionTitle,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            FutureBuilder<List<Object>>(
              future: _conversationListFuture,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done &&
                    !snap.hasData) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.spacing4,
                      vertical: AppTheme.spacing1,
                    ),
                    child: Text(
                      t.loadingConversations,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  );
                }
                if (!snap.hasData) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.spacing4,
                      vertical: AppTheme.spacing1,
                    ),
                    child: Text(
                      t.noConversations,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  );
                }
                final list = (snap.data![0] as List)
                    .cast<Map<String, dynamic>>();
                final active = (snap.data![1] as String?) ?? '';
                if (list.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.spacing4,
                      vertical: AppTheme.spacing1,
                    ),
                    child: Text(
                      t.noConversations,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  );
                }

                String normalizedParent(Map<String, dynamic> row) {
                  final String cid = ((row['cid'] as String?) ?? '').trim();
                  final String parentRaw =
                      ((row['parent_cid'] as String?) ?? '').trim();
                  final String lower = parentRaw.toLowerCase();
                  if (parentRaw.isEmpty ||
                      lower == 'null' ||
                      lower == 'undefined' ||
                      parentRaw == cid) {
                    return '';
                  }
                  return parentRaw;
                }

                final Set<String> allCids = list
                    .map((row) => ((row['cid'] as String?) ?? '').trim())
                    .where((cid) => cid.isNotEmpty)
                    .toSet();

                // 将当前激活会话置顶
                final rootList = list
                    .where((row) {
                      final String parent = normalizedParent(row);
                      return parent.isEmpty || !allCids.contains(parent);
                    })
                    .toList(growable: false);
                final Map<String, List<Map<String, dynamic>>> childrenByParent =
                    <String, List<Map<String, dynamic>>>{};
                for (final row in list) {
                  final String parent = normalizedParent(row);
                  if (parent.isEmpty || !allCids.contains(parent)) {
                    continue;
                  }
                  childrenByParent
                      .putIfAbsent(parent, () => <Map<String, dynamic>>[])
                      .add(row);
                }
                final sortedList = List<Map<String, dynamic>>.from(
                  rootList.isEmpty ? list : rootList,
                );
                sortedList.sort((a, b) {
                  final aCid = (a['cid'] as String?) ?? '';
                  final bCid = (b['cid'] as String?) ?? '';
                  if (aCid == active) return -1;
                  if (bCid == active) return 1;
                  // 其他按更新时间倒序
                  final aTime = (a['updated_at'] as int?) ?? 0;
                  final bTime = (b['updated_at'] as int?) ?? 0;
                  return bTime.compareTo(aTime);
                });
                try {
                  final String sample = list.isEmpty
                      ? '-'
                      : [
                          'cid=${((list.first['cid'] as String?) ?? '').trim()}',
                          'parent=${((list.first['parent_cid'] as String?) ?? '').trim()}',
                          'kind=${((list.first['conversation_kind'] as String?) ?? '').trim()}',
                          'title=${((list.first['title'] as String?) ?? '').trim()}',
                        ].join(' ');
                  FlutterLogger.nativeInfo(
                    'UI',
                    'SideDrawer conversations total=${list.length} roots=${rootList.length} children=${childrenByParent.length} sorted=${sortedList.length} active=$active sample=$sample',
                  );
                } catch (_) {}
                if (sortedList.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.spacing4,
                      vertical: AppTheme.spacing1,
                    ),
                    child: Text(
                      t.noConversations,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  );
                }

                return Column(
                  children: sortedList.map((c) {
                    final cid = (c['cid'] as String?) ?? '';
                    final rawTitle = (c['title'] as String?) ?? '';
                    final title = rawTitle.trim().isEmpty
                        ? t.untitledConversationLabel
                        : rawTitle;
                    final model = (c['model'] as String?) ?? '';
                    final isActive = active == cid;

                    final List<Map<String, dynamic>> children =
                        List<Map<String, dynamic>>.from(
                          childrenByParent[cid] ??
                              const <Map<String, dynamic>>[],
                        );
                    children.sort((a, b) {
                      final aTime = (a['updated_at'] as int?) ?? 0;
                      final bTime = (b['updated_at'] as int?) ?? 0;
                      return bTime.compareTo(aTime);
                    });
                    final bool hasChildren = children.isNotEmpty;
                    final bool hasActiveChild = children.any((child) {
                      final childCid = ((child['cid'] as String?) ?? '').trim();
                      return childCid.isNotEmpty && childCid == active;
                    });
                    return StatefulBuilder(
                      key: ValueKey<String>('conversation-tree-$cid'),
                      builder: (context, rowSetState) {
                        final bool defaultExpanded = isActive || hasActiveChild;
                        final bool isExpanded =
                            hasChildren &&
                            (_conversationExpansionByCid[cid] ??
                                defaultExpanded);
                        return Column(
                          children: [
                            _buildConversationItem(
                              context: context,
                              cid: cid,
                              title: title,
                              model: model,
                              isActive: isActive,
                              hasChildren: hasChildren,
                              isExpanded: isExpanded,
                              onToggleChildren: hasChildren
                                  ? () {
                                      _conversationExpansionByCid[cid] =
                                          !isExpanded;
                                      rowSetState(() {});
                                    }
                                  : null,
                            ),
                            if (hasChildren)
                              ClipRect(
                                child: AnimatedSize(
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  child: isExpanded
                                      ? Column(
                                          children: [
                                            for (final child in children)
                                              _buildSubagentConversationItem(
                                                context: context,
                                                row: child,
                                              ),
                                          ],
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 构建菜单项（完全复用设置页面的样式）
  Widget _buildMenuItem({
    required BuildContext context,
    required IconData icon,
    required String title,
    required bool isFirst,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final Color iconColor = theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.all(AppTheme.spacing3),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
            width: 1,
          ),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: Center(child: Icon(icon, color: iconColor, size: 20)),
            ),
            const SizedBox(width: AppTheme.spacing3),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppTheme.mutedForeground,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建会话列表项（支持长按删除，显示模型图标）
  Widget _buildConversationItem({
    required BuildContext context,
    required String cid,
    required String title,
    required String model,
    required bool isActive,
    bool hasChildren = false,
    bool isExpanded = false,
    VoidCallback? onToggleChildren,
  }) {
    final theme = Theme.of(context);
    final t = AppLocalizations.of(context);

    return Container(
      decoration: BoxDecoration(
        color: isActive
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.15)
            : Colors.transparent,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
            width: 1,
          ),
        ),
      ),
      child: InkWell(
        onTap: () async {
          try {
            await AISettingsService.instance.setActiveConversationCid(cid);
          } catch (_) {}
          if (!context.mounted) return;
          Navigator.of(context).pop();
        },
        onLongPress: () async {
          // 使用自定义对话框
          await showUIDialog<void>(
            context: context,
            title: t.deleteConversationTitle,
            message: t.confirmDeleteConversationMessage(title),
            actions: [
              UIDialogAction(text: t.dialogCancel),
              UIDialogAction(
                text: t.actionDelete,
                style: UIDialogActionStyle.destructive,
                onPressed: (ctx) async {
                  try {
                    final sw = Stopwatch()..start();
                    Navigator.of(ctx).pop();
                    final ok = await AISettingsService.instance
                        .deleteConversation(cid);
                    sw.stop();
                    if (!context.mounted) return;
                    if (!mounted) return;
                    _refreshConversationList();
                    try {
                      await FlutterLogger.nativeInfo(
                        'UI',
                        'SideDrawer 删除对话总耗时(毫秒)=${sw.elapsedMilliseconds}',
                      );
                    } catch (_) {}
                    // 记录“完全清空”耗时：从删除返回到FutureBuilder下一次完成的时间
                    final sw2 = Stopwatch()..start();
                    // 触发一次 rebuild 后，在下一帧读取列表为空的时刻打印
                    WidgetsBinding.instance.addPostFrameCallback((_) async {
                      sw2.stop();
                      try {
                        await FlutterLogger.nativeInfo(
                          'UI',
                          'SideDrawer 清空后首帧耗时(毫秒)=${sw2.elapsedMilliseconds}',
                        );
                      } catch (_) {}
                    });
                    if (!mounted) return;
                    if (!ok) {
                      UINotifier.error(this.context, t.deleteFailed);
                    } else {
                      UINotifier.success(this.context, t.deletedToast);
                    }
                  } catch (e) {
                    if (!ctx.mounted) return;
                    UINotifier.error(
                      ctx,
                      t.deleteFailedWithError(e.toString()),
                    );
                  }
                },
              ),
            ],
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacing3,
            vertical: AppTheme.spacing3,
          ),
          child: Row(
            children: [
              // 显示模型图标（使用原始SVG颜色）
              SizedBox(
                width: 36,
                height: 36,
                child: model.isNotEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: ModelLogo(modelId: model, size: 20),
                      )
                    : Icon(
                        Icons.chat_bubble_outline,
                        color: theme.colorScheme.onSurfaceVariant,
                        size: 18,
                      ),
              ),
              const SizedBox(width: AppTheme.spacing3),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    color: isActive ? theme.colorScheme.primary : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isActive)
                hasChildren
                    ? const SizedBox.shrink()
                    : Icon(
                        Icons.chevron_right,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
              if (hasChildren)
                InkWell(
                  onTap: onToggleChildren,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: isActive
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubagentConversationItem({
    required BuildContext context,
    required Map<String, dynamic> row,
  }) {
    final theme = Theme.of(context);
    final String cid = ((row['cid'] as String?) ?? '').trim();
    final String titleRaw = ((row['title'] as String?) ?? '').trim();
    final String title = titleRaw.isEmpty ? 'Subagent' : titleRaw;
    final String model = ((row['model'] as String?) ?? '').trim();
    final int tokens = (row['subagent_context_tokens'] as int?) ?? 0;
    final int cap = (row['subagent_context_cap_tokens'] as int?) ?? 0;
    final String contextPercentLabel = _formatSubagentContextPercent(
      tokens: tokens,
      cap: cap,
    );
    return Padding(
      padding: const EdgeInsets.only(left: AppTheme.spacing5),
      child: InkWell(
        onTap: cid.isEmpty
            ? null
            : () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AISettingsPage(conversationCid: cid, readOnly: true),
                  ),
                );
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacing3,
            vertical: AppTheme.spacing2,
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                child: model.isEmpty
                    ? Icon(
                        Icons.smart_toy_outlined,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : Padding(
                        padding: const EdgeInsets.all(5),
                        child: ModelLogo(modelId: model, size: 14),
                      ),
              ),
              const SizedBox(width: AppTheme.spacing2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (model.isNotEmpty)
                      Text(
                        model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.78,
                          ),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.spacing2),
              Text(
                contextPercentLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatSubagentContextPercent({
    required int tokens,
    required int cap,
  }) {
    if (tokens <= 0 || cap <= 0) return '-';
    final double percent = tokens * 100.0 / cap;
    if (percent > 0 && percent < 0.1) return '<0.1%';
    if (percent < 10) {
      return '${percent.toStringAsFixed(1)}%';
    }
    return '${percent.round().clamp(0, 999)}%';
  }
}
