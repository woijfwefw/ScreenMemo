part of 'settings_page.dart';

// ========== App 运行状态 ==========
extension _SettingsAppHealthPart on _SettingsPageState {
  Future<void> _loadAppHealthStatus({bool refresh = false}) async {
    if (_appHealthLoading) {
      _appHealthReloadQueued = true;
      return;
    }
    _settingsSetState(() => _appHealthLoading = true);
    try {
      final snapshot = refresh
          ? await AppHealthService.instance.refreshAndLoadSnapshot(
              range: _appHealthRange,
              slotSize: _appHealthSlotSize,
            )
          : await AppHealthService.instance.loadDashboardSnapshot(
              range: _appHealthRange,
              slotSize: _appHealthSlotSize,
            );
      if (!mounted) return;
      _settingsSetState(() => _appHealthSnapshot = snapshot);
    } catch (e) {
      if (!mounted) return;
      UINotifier.error(context, 'Failed to load app health');
    } finally {
      if (mounted) {
        _settingsSetState(() => _appHealthLoading = false);
        if (_appHealthReloadQueued) {
          _appHealthReloadQueued = false;
          unawaited(_loadAppHealthStatus());
        }
      }
    }
  }

  Widget _buildAppHealthPage(BuildContext context) {
    final snapshot = _appHealthSnapshot;
    if (_appHealthLoading && snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot == null) {
      return ListView(
        padding: _settingsListPadding(),
        children: [_buildAppHealthEmptyCard(context)],
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadAppHealthStatus(refresh: true),
      child: ListView(
        padding: _settingsListPadding(),
        children: [
          _buildAppHealthSummaryCard(context, snapshot),
          const SizedBox(height: AppTheme.spacing3),
          ...snapshot.current.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.spacing3),
              child: _buildAppHealthComponentCard(
                context,
                item,
                snapshot.bucketsForComponent(item.component),
              ),
            ),
          ),
          _buildAppHealthEventsCard(context, snapshot),
        ],
      ),
    );
  }

  Widget _buildAppHealthEmptyCard(BuildContext context) {
    final theme = Theme.of(context);
    return _buildHealthSurface(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'App 运行状态',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.spacing2),
          Text(
            '暂无健康状态数据。下拉刷新或点击右上角刷新后，会写入结构化状态记录。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.spacing3),
          FilledButton.icon(
            onPressed: () => _loadAppHealthStatus(refresh: true),
            icon: const Icon(Icons.refresh),
            label: const Text('刷新状态'),
          ),
        ],
      ),
    );
  }

  void _showAppHealthTimelineSheet() {
    final theme = Theme.of(context);
    final snapshot = _appHealthSnapshot;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: theme.colorScheme.surface,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final currentSnapshot = _appHealthSnapshot ?? snapshot;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: AppTheme.spacing4,
                  right: AppTheme.spacing4,
                  bottom:
                      MediaQuery.of(sheetContext).viewInsets.bottom +
                      AppTheme.spacing4,
                ),
                child: currentSnapshot == null
                    ? _buildAppHealthTimelineEmptySheet(sheetContext)
                    : _buildAppHealthTimelineControls(
                        sheetContext,
                        currentSnapshot,
                        asSheet: true,
                        afterSelectionChanged: () => setSheetState(() {}),
                      ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAppHealthTimelineEmptySheet(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '时间线视图',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppTheme.spacing2),
        Text(
          '暂无健康状态数据。请先刷新状态后再调整时间线视图。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppTheme.spacing3),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            _loadAppHealthStatus(refresh: true);
          },
          icon: const Icon(Icons.refresh),
          label: const Text('刷新状态'),
        ),
      ],
    );
  }

  Widget _buildAppHealthTimelineControls(
    BuildContext context,
    AppHealthDashboardSnapshot snapshot, {
    bool asSheet = false,
    VoidCallback? afterSelectionChanged,
  }) {
    final theme = Theme.of(context);
    final rangeOptions = _appHealthRangeOptions();
    final slotOptions = _appHealthSlotOptions();

    final content = Column(
      mainAxisSize: asSheet ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '时间线视图',
                style:
                    (asSheet
                            ? theme.textTheme.titleMedium
                            : theme.textTheme.titleSmall)
                        ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton.icon(
              onPressed: () => _showAppHealthCustomRangeDialog(
                afterApply: afterSelectionChanged,
              ),
              icon: const Icon(Icons.tune_rounded, size: 16),
              label: const Text('自定义小时'),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacing2),
        _buildAppHealthSliderGroup(
          context,
          label: '范围',
          values: rangeOptions,
          selected: _appHealthRange,
          onSelected: (value) {
            _changeAppHealthWindow(range: value);
            afterSelectionChanged?.call();
          },
        ),
        const SizedBox(height: AppTheme.spacing2),
        _buildAppHealthSliderGroup(
          context,
          label: '每格',
          values: slotOptions,
          selected: _appHealthSlotSize,
          onSelected: (value) {
            _changeAppHealthWindow(slotSize: value);
            afterSelectionChanged?.call();
          },
        ),
        if (snapshot.slotSizeAdjusted) ...[
          const SizedBox(height: AppTheme.spacing2),
          Text(
            '当前范围过长，已自动聚合为每格 ${snapshot.slotLabel}，最多展示 ${AppHealthService.maxBucketCount} 段。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.orange.shade700,
            ),
          ),
        ],
      ],
    );

    if (asSheet) return content;
    return _buildHealthSurface(context, child: content);
  }

  List<Duration> _appHealthRangeOptions() {
    final values = <Duration>[
      AppHealthService.defaultRange,
      const Duration(hours: 6),
      const Duration(hours: 24),
      const Duration(days: 7),
      const Duration(days: 30),
    ];
    if (!values.contains(_appHealthRange)) {
      values.add(_appHealthRange);
      values.sort((a, b) => a.inMilliseconds.compareTo(b.inMilliseconds));
    }
    return values;
  }

  List<Duration> _appHealthSlotOptions() {
    final values = <Duration>[
      const Duration(minutes: 1),
      const Duration(minutes: 5),
      const Duration(minutes: 30),
      const Duration(hours: 1),
      const Duration(hours: 6),
    ];
    if (!values.contains(_appHealthSlotSize)) {
      values.add(_appHealthSlotSize);
      values.sort((a, b) => a.inMilliseconds.compareTo(b.inMilliseconds));
    }
    return values;
  }

  Widget _buildAppHealthSliderGroup(
    BuildContext context, {
    required String label,
    required List<Duration> values,
    required Duration selected,
    required ValueChanged<Duration> onSelected,
  }) {
    final theme = Theme.of(context);
    final options = <Duration, String>{
      for (final value in values) value: AppHealthDurationLabels.compact(value),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              AppHealthDurationLabels.compact(selected),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacing1),
        _AppHealthSegmentedSlider<Duration>(
          value: selected,
          options: options,
          onChanged: onSelected,
        ),
      ],
    );
  }

  void _changeAppHealthWindow({Duration? range, Duration? slotSize}) {
    _settingsSetState(() {
      if (range != null) _appHealthRange = range;
      if (slotSize != null) _appHealthSlotSize = slotSize;
    });
    _appHealthWindowDebounce?.cancel();
    _appHealthWindowDebounce = Timer(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      unawaited(_loadAppHealthStatus());
    });
  }

  void _showAppHealthCustomRangeDialog({VoidCallback? afterApply}) {
    final controller = TextEditingController(
      text: math.max(1, (_appHealthRange.inMinutes / 60).round()).toString(),
    );
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('自定义时间范围'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '最近多少小时',
              hintText: '例如 12',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final hours = int.tryParse(controller.text.trim());
                if (hours == null || hours <= 0) {
                  UINotifier.error(context, 'Invalid range hours');
                  return;
                }
                Navigator.of(dialogContext).pop();
                _changeAppHealthWindow(
                  range: Duration(hours: hours.clamp(1, 24 * 365).toInt()),
                );
                afterApply?.call();
              },
              child: const Text('应用'),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  Widget _buildAppHealthSummaryCard(
    BuildContext context,
    AppHealthDashboardSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final color = _appHealthStatusColor(
      context,
      snapshot.overallStatus,
      snapshot.overallSeverity,
    );
    final String successText = snapshot.successRate == null
        ? '暂无成功率'
        : '成功率 ${(snapshot.successRate! * 100).toStringAsFixed(1)}%';
    final String checkedText = snapshot.lastCheckedAt <= 0
        ? '尚未检查'
        : '最近检查 ${_formatHealthTime(snapshot.lastCheckedAt)}';

    return _buildHealthSurface(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                ),
                child: Icon(Icons.monitor_heart_outlined, color: color),
              ),
              const SizedBox(width: AppTheme.spacing3),
              Expanded(
                child: Text(
                  'App 运行状态',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.spacing2),
              Text(
                snapshot.overallLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_appHealthLoading) ...[
                const SizedBox(width: AppTheme.spacing2),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppTheme.spacing3),
          _buildAppHealthStatusBars(context, snapshot.buckets),
          const SizedBox(height: AppTheme.spacing1),
          Text(
            _appHealthTimelineHint(snapshot),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.spacing3),
          Row(
            children: [
              Expanded(
                child: _buildHealthMetric(context, successText, '请求与检查'),
              ),
              _buildHealthDivider(context),
              Expanded(
                child: _buildHealthMetric(
                  context,
                  '${snapshot.unhealthyCount}',
                  '异常模块',
                ),
              ),
              _buildHealthDivider(context),
              Expanded(child: _buildHealthMetric(context, checkedText, '时间')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppHealthStatusBars(
    BuildContext context,
    List<AppHealthBucketSlot> buckets, {
    double height = 32,
  }) {
    final theme = Theme.of(context);
    final int barCount = buckets.isEmpty
        ? AppHealthService.defaultBucketCount
        : buckets.length;
    final bool scrollable = barCount > 180;
    Widget buildBar(int index, {required bool expanded}) {
      final slot = buckets.isEmpty ? null : buckets[index];
      final color = slot == null
          ? theme.colorScheme.outline.withValues(alpha: 0.25)
          : _appHealthStatusColor(context, slot.status, slot.severity);
      final double alpha = slot == null || slot.checkedCount == 0 ? 0.35 : 1.0;
      final child = Tooltip(
        message: slot == null ? '暂无数据' : _appHealthBucketTooltip(slot),
        waitDuration: const Duration(milliseconds: 350),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: slot == null
              ? null
              : () => _showAppHealthBucketSheet(context, slot),
          onLongPress: slot == null
              ? null
              : () => _showAppHealthBucketSheet(context, slot),
          child: Container(
            height: height,
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        ),
      );
      if (!expanded) {
        return SizedBox(width: 6, child: child);
      }
      return Expanded(child: child);
    }

    final bars = List.generate(
      barCount,
      (index) => buildBar(index, expanded: !scrollable),
    );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: scrollable
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: bars),
            )
          : Row(children: bars),
    );
  }

  Widget _buildAppHealthComponentCard(
    BuildContext context,
    AppHealthCurrentStatus item,
    List<AppHealthBucketSlot> buckets,
  ) {
    final theme = Theme.of(context);
    final color = _appHealthStatusColor(context, item.status, item.severity);
    final String successRate = item.successRate == null
        ? '—'
        : '${(item.successRate! * 100).toStringAsFixed(1)}%';
    final String lastError = (item.lastErrorMessage ?? '').trim();
    final String? actionLabel = _appHealthActionLabel(item.component);

    return _buildHealthSurface(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Icon(
                  _appHealthComponentIcon(item.component),
                  size: 18,
                  color: color,
                ),
              ),
              const SizedBox(width: AppTheme.spacing3),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.componentLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (actionLabel != null) ...[
                      const SizedBox(height: 2),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () =>
                              _handleAppHealthAction(item.component),
                          style: TextButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 24),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  actionLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 2),
                              const Icon(Icons.arrow_forward_rounded, size: 14),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.spacing2),
              Text(
                item.statusLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing3),
          _buildAppHealthStatusBars(context, buckets, height: 18),
          const SizedBox(height: AppTheme.spacing1),
          Text(
            '每格 ${_appHealthSnapshot?.slotLabel ?? '1分钟'} · 点击或悬停查看统计',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.spacing3),
          Row(
            children: [
              Expanded(
                child: _buildHealthMetric(
                  context,
                  item.lastSuccessAt <= 0
                      ? '—'
                      : _formatHealthTime(item.lastSuccessAt),
                  '最近成功',
                ),
              ),
              _buildHealthDivider(context),
              Expanded(
                child: _buildHealthMetric(
                  context,
                  item.lastFailureAt <= 0
                      ? '—'
                      : _formatHealthTime(item.lastFailureAt),
                  '最近失败',
                ),
              ),
              _buildHealthDivider(context),
              Expanded(child: _buildHealthMetric(context, successRate, '成功率')),
            ],
          ),
          if (lastError.isNotEmpty) ...[
            const SizedBox(height: AppTheme.spacing3),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppTheme.spacing3),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.errorContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: Text(
                lastError,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAppHealthEventsCard(
    BuildContext context,
    AppHealthDashboardSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final filters = <String>[
      'all',
      ...snapshot.current.map((item) => item.component),
    ];
    final events = snapshot.events
        .where((event) {
          return _appHealthEventFilter == 'all' ||
              event.component == _appHealthEventFilter;
        })
        .toList(growable: false);

    return _buildHealthSurface(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '关键事件',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.spacing2),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: filters
                  .map((filter) {
                    final selected = _appHealthEventFilter == filter;
                    return Padding(
                      padding: const EdgeInsets.only(right: AppTheme.spacing2),
                      child: ChoiceChip(
                        label: Text(
                          filter == 'all'
                              ? '全部'
                              : AppHealthCurrentStatus.empty(
                                  filter,
                                ).componentLabel,
                        ),
                        selected: selected,
                        onSelected: (_) {
                          _settingsSetState(
                            () => _appHealthEventFilter = filter,
                          );
                        },
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
          ),
          const SizedBox(height: AppTheme.spacing2),
          if (events.isEmpty)
            Text(
              '暂无关键事件',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...events
                .take(20)
                .map((event) => _buildAppHealthEventRow(context, event)),
        ],
      ),
    );
  }

  Widget _buildAppHealthEventRow(BuildContext context, AppHealthEvent event) {
    final theme = Theme.of(context);
    final color = _appHealthStatusColor(context, event.status, event.severity);
    final String message = (event.errorMessage ?? '').trim().isNotEmpty
        ? event.errorMessage!.trim()
        : event.eventType;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppTheme.spacing2),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.16),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppTheme.spacing2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${event.componentLabel} · ${event.eventType}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.spacing2),
          Text(
            _formatHealthTime(event.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _showAppHealthBucketSheet(
    BuildContext context,
    AppHealthBucketSlot slot,
  ) {
    final theme = Theme.of(context);
    final color = _appHealthStatusColor(context, slot.status, slot.severity);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surface,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacing4,
              0,
              AppTheme.spacing4,
              AppTheme.spacing4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppTheme.spacing2),
                    Text(
                      '状态条统计',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.spacing3),
                _buildBucketDetailRow(
                  context,
                  '时间范围',
                  _formatHealthRange(slot.bucketStart, slot.bucketEnd),
                ),
                _buildBucketDetailRow(
                  context,
                  '状态',
                  _appHealthStatusText(slot.status, slot.severity),
                ),
                _buildBucketDetailRow(context, '检查次数', '${slot.checkedCount}'),
                _buildBucketDetailRow(
                  context,
                  '成功 / 失败',
                  '${slot.successCount} / ${slot.failureCount}',
                ),
                _buildBucketDetailRow(
                  context,
                  '失败率',
                  slot.checkedCount <= 0
                      ? '—'
                      : '${((slot.failureCount / slot.checkedCount) * 100).toStringAsFixed(1)}%',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBucketDetailRow(
    BuildContext context,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spacing2),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHealthSurface(BuildContext context, {required Widget child}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacing4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.16),
        ),
      ),
      child: child,
    );
  }

  Widget _buildHealthMetric(BuildContext context, String value, String label) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildHealthDivider(BuildContext context) {
    return Container(
      width: 1,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacing2),
      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.24),
    );
  }

  Color _appHealthStatusColor(
    BuildContext context,
    String status,
    int severity,
  ) {
    final theme = Theme.of(context);
    if (status == AppHealthStatusValues.ok) return AppTheme.success;
    if (status == AppHealthStatusValues.failed ||
        severity >= AppHealthSeverity.critical) {
      return theme.colorScheme.error;
    }
    if (status == AppHealthStatusValues.degraded ||
        severity >= AppHealthSeverity.warning) {
      return Colors.orange.shade700;
    }
    if (status == AppHealthStatusValues.idle) return AppTheme.info;
    return theme.colorScheme.onSurfaceVariant;
  }

  IconData _appHealthComponentIcon(String component) {
    switch (component) {
      case AppHealthComponents.captureService:
        return Icons.camera_alt_outlined;
      case AppHealthComponents.permissions:
        return Icons.verified_user_outlined;
      case AppHealthComponents.database:
        return Icons.storage_outlined;
      case AppHealthComponents.storage:
        return Icons.folder_outlined;
      case AppHealthComponents.aiProcessing:
        return Icons.auto_awesome_outlined;
      case AppHealthComponents.backgroundTasks:
        return Icons.sync_outlined;
      default:
        return Icons.monitor_heart_outlined;
    }
  }

  String? _appHealthActionLabel(String component) {
    switch (component) {
      case AppHealthComponents.permissions:
        return '检查权限';
      case AppHealthComponents.captureService:
        return '打开截屏设置';
      case AppHealthComponents.storage:
      case AppHealthComponents.database:
        return '查看数据与备份';
      case AppHealthComponents.aiProcessing:
        return '查看 AI 设置';
      case AppHealthComponents.backgroundTasks:
        return '查看后台任务';
      default:
        return null;
    }
  }

  void _handleAppHealthAction(String component) {
    switch (component) {
      case AppHealthComponents.permissions:
        _switchSubPage(_SettingsSubPage.permissions);
        break;
      case AppHealthComponents.captureService:
        _switchSubPage(_SettingsSubPage.screenshot);
        break;
      case AppHealthComponents.storage:
      case AppHealthComponents.database:
      case AppHealthComponents.backgroundTasks:
        _switchSubPage(_SettingsSubPage.dataBackup);
        break;
      case AppHealthComponents.aiProcessing:
        _switchSubPage(_SettingsSubPage.segmentSummary);
        break;
    }
  }

  String _formatHealthTime(int millis) {
    if (millis <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${two(dt.hour)}:${two(dt.minute)}';
    }
    return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  String _formatHealthDateTime(int millis) {
    if (millis <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  String _formatHealthRange(int start, int end) {
    return '${_formatHealthDateTime(start)} - ${_formatHealthDateTime(end)}';
  }

  String _appHealthBucketTooltip(AppHealthBucketSlot slot) {
    return [
      _formatHealthRange(slot.bucketStart, slot.bucketEnd),
      _appHealthStatusText(slot.status, slot.severity),
      '检查 ${slot.checkedCount} · 成功 ${slot.successCount} · 失败 ${slot.failureCount}',
    ].join('\n');
  }

  String _appHealthTimelineHint(AppHealthDashboardSnapshot snapshot) {
    final String adjusted = snapshot.slotSizeAdjusted ? ' · 自动聚合' : '';
    return '每格 ${snapshot.slotLabel} · 最近 ${snapshot.rangeLabel}$adjusted · 点击或悬停查看统计';
  }

  String _appHealthStatusText(String status, int severity) {
    if (status == AppHealthStatusValues.ok) return '正常';
    if (status == AppHealthStatusValues.failed ||
        severity >= AppHealthSeverity.critical) {
      return '失败';
    }
    if (status == AppHealthStatusValues.degraded ||
        severity >= AppHealthSeverity.warning) {
      return '降级';
    }
    if (status == AppHealthStatusValues.idle) return '等待中';
    if (status == AppHealthStatusValues.disabled) return '已关闭';
    return '暂无数据';
  }
}

class _AppHealthSegmentedSlider<T> extends StatelessWidget {
  const _AppHealthSegmentedSlider({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = options.entries.toList(growable: false);
    final int selectedIndex = entries.indexWhere((entry) => entry.key == value);
    final int currentIndex = selectedIndex >= 0 ? selectedIndex : 0;
    final TextStyle baseStyle =
        theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.1,
        ) ??
        const TextStyle(fontWeight: FontWeight.w600, height: 1.1);

    void updateByDx(double dx, double width, double segmentWidth) {
      if (entries.length <= 1 || segmentWidth <= 0 || width <= 0) return;
      final double clampedDx = dx.clamp(0.0, width - 0.001).toDouble();
      final int nextIndex = (clampedDx / segmentWidth)
          .floor()
          .clamp(0, entries.length - 1)
          .toInt();
      if (nextIndex != currentIndex) {
        onChanged(entries[nextIndex].key);
      }
    }

    return Container(
      padding: const EdgeInsets.all(AppTheme.spacing1),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double width = constraints.maxWidth;
          final double segmentWidth = entries.isEmpty
              ? width
              : width / entries.length;
          final double indicatorLeft = segmentWidth * currentIndex;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: entries.length > 1
                ? (details) =>
                      updateByDx(details.localPosition.dx, width, segmentWidth)
                : null,
            onHorizontalDragUpdate: entries.length > 1
                ? (details) =>
                      updateByDx(details.localPosition.dx, width, segmentWidth)
                : null,
            child: SizedBox(
              height: 34,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                child: Stack(
                  children: [
                    if (entries.isNotEmpty)
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        left: indicatorLeft,
                        top: 0,
                        bottom: 0,
                        width: segmentWidth,
                        child: IgnorePointer(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: cs.surface,
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusSm,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Row(
                      children: entries
                          .map((entry) {
                            final bool selected = entry.key == value;
                            return Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => onChanged(entry.key),
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppTheme.spacing1,
                                      vertical: 6,
                                    ),
                                    child: Text(
                                      entry.value,
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      strutStyle: const StrutStyle(
                                        height: 1.1,
                                        forceStrutHeight: true,
                                      ),
                                      style: baseStyle.copyWith(
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w600,
                                        color: selected
                                            ? cs.onSurface
                                            : cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          })
                          .toList(growable: false),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
