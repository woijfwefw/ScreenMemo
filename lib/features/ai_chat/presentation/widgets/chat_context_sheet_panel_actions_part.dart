part of 'chat_context_sheet.dart';

extension _ChatContextPanelActionsPart on _ChatContextPanelState {
  Future<void> _loadModelInfo() async {
    try {
      final String model = await AISettingsService.instance.getModel();
      final int ctx = (await AIContextBudgets.forModelWithOverrides(
        model,
      )).promptCapTokens.clamp(256, 1 << 30).toInt();
      if (!mounted) return;
      _panelSetState(() {
        _activeModel = model;
        _activeModelContextTokens = ctx;
      });
    } catch (_) {}
  }

  String _trimEventTitle(ChatContextEvent event) {
    final NumberFormat nf = NumberFormat.decimalPattern();
    return ChatContextSheet._loc(
      context,
      '裁剪 ${nf.format(event.droppedTokens)} token',
      'Trimmed ${nf.format(event.droppedTokens)} tokens',
    );
  }

  String _trimEventSubtitle(ChatContextEvent event) {
    final NumberFormat nf = NumberFormat.decimalPattern();
    final String tokens =
        '${nf.format(event.beforeTokens)} → ${nf.format(event.afterTokens)}';
    final String dropped = nf.format(event.droppedTokens);
    final String reason = event.reason.isEmpty ? '-' : event.reason;
    return ChatContextSheet._loc(
      context,
      'tokens: $tokens，丢弃: $dropped，原因: $reason',
      'tokens: $tokens, dropped: $dropped, reason: $reason',
    );
  }

  Widget _trimEventsCard(BuildContext context, List<ChatContextEvent> events) {
    final ThemeData theme = Theme.of(context);
    final List<ChatContextEvent> shown =
        events.length > _ChatContextPanelState._trimEventsMaxLimit
        ? events.sublist(0, _ChatContextPanelState._trimEventsMaxLimit)
        : events;
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacing3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ChatContextSheet._loc(context, 'Token 裁剪事件', 'Token trim events'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.spacing1),
          Text(
            ChatContextSheet._loc(
              context,
              '最近 ${shown.length} 条',
              'Latest ${shown.length} events',
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.spacing2),
          if (shown.isEmpty)
            Text(
              ChatContextSheet._loc(
                context,
                '暂无 token 丢弃事件',
                'No token trim events yet.',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...shown.map(
              (e) => Container(
                margin: const EdgeInsets.only(bottom: AppTheme.spacing2),
                padding: const EdgeInsets.all(AppTheme.spacing2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _trimEventTitle(e),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacing1),
                    Text(
                      _trimEventSubtitle(e),
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ChatContextSheet._loc(
                        context,
                        '时间：${ChatContextSheet._fmtTs(e.createdAtMs)}',
                        'Time: ${ChatContextSheet._fmtTs(e.createdAtMs)}',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
