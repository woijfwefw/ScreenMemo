part of 'segment_status_page.dart';

// ========== 动态页提供商选择 ==========
extension _SegmentStatusProviderPart on _SegmentStatusPageState {
  Future<void> _loadDynamicEntryLogIconEnabled() async {
    try {
      final bool enabled = await UserSettingsService.instance.getBool(
        UserSettingKeys.dynamicEntryLogIconEnabled,
        defaultValue: false,
      );
      if (!mounted) return;
      _segmentStatusSetState(() => _dynamicEntryLogIconEnabled = enabled);
    } catch (_) {}
  }

  // 载入“动态(segments)”的提供商/模型选择（独立于对话页）
  Future<void> _loadSegmentsContextSelection() async {
    final Stopwatch sw = Stopwatch()..start();
    _beginEntryPerfLoad('segment.context');
    try {
      final svc = AIProvidersService.instance;
      final Stopwatch providersSw = Stopwatch()..start();
      final providers = await svc.listProviders();
      DynamicEntryPerfService.instance.mark(
        'segment.context.providers.done',
        detail:
            'ms=${providersSw.elapsedMilliseconds} count=${providers.length}',
      );
      if (providers.isEmpty) {
        if (mounted) {
          _segmentStatusSetState(() {
            _ctxSegProvider = null;
            _ctxSegModel = null;
          });
        }
        _endEntryPerfLoad(
          'segment.context',
          detail: 'ms=${sw.elapsedMilliseconds} providers=0',
        );
        return;
      }
      final Stopwatch contextRowSw = Stopwatch()..start();
      final ctxRow = await AISettingsService.instance.getAIContextRow(
        'segments',
      );
      DynamicEntryPerfService.instance.mark(
        'segment.context.selection.done',
        detail:
            'ms=${contextRowSw.elapsedMilliseconds} hasRow=${ctxRow != null} providerId=${ctxRow?['provider_id'] ?? ''}',
      );
      AIProvider? sel;
      AIProvider? defaultProvider;
      final int? selectedProviderId = ctxRow?['provider_id'] as int?;
      final Stopwatch resolveSw = Stopwatch()..start();
      for (final AIProvider provider in providers) {
        if (selectedProviderId != null && provider.id == selectedProviderId) {
          sel = provider;
        }
        if (defaultProvider == null && provider.isDefault) {
          defaultProvider = provider;
        }
      }
      sel ??= defaultProvider;
      sel ??= providers.first;

      String model =
          (ctxRow != null &&
              (ctxRow['model'] as String?)?.trim().isNotEmpty == true)
          ? (ctxRow['model'] as String).trim()
          : ((sel.extra['active_model'] as String?) ?? sel.defaultModel)
                .toString();
      if (model.isEmpty && sel.models.isNotEmpty) model = sel.models.first;
      DynamicEntryPerfService.instance.mark(
        'segment.context.resolve.done',
        detail:
            'ms=${resolveSw.elapsedMilliseconds} provider=${sel.name} model=$model',
      );

      if (mounted) {
        _segmentStatusSetState(() {
          _ctxSegProvider = sel;
          _ctxSegModel = model;
        });
      }
      _endEntryPerfLoad(
        'segment.context',
        detail:
            'ms=${sw.elapsedMilliseconds} providers=${providers.length} provider=${sel.name} model=$model',
      );
    } catch (e) {
      _failEntryPerfLoad(
        'segment.context',
        e,
        detail: 'ms=${sw.elapsedMilliseconds}',
      );
    }
  }

  Future<void> _showProviderSheetSegments() async {
    final svc = AIProvidersService.instance;
    final list = await svc.listProviders();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final currentId = _ctxSegProvider?.id ?? -1;
        // 使用持久化查询文本，避免键盘开合/重建导致输入被清空
        final TextEditingController queryCtrl = TextEditingController(
          text: _segProviderQueryText,
        );
        return StatefulBuilder(
          builder: (c, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.8,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (_, scrollCtrl) {
                final q = queryCtrl.text.trim().toLowerCase();
                final filtered = list.where((p) {
                  if (q.isEmpty) return true;
                  final name = p.name.toLowerCase();
                  final type = p.type.toLowerCase();
                  final base = (p.baseUrl ?? '').toString().toLowerCase();
                  return name.contains(q) ||
                      type.contains(q) ||
                      base.contains(q);
                }).toList();
                // 将当前选中的提供商置顶，便于观察
                final selIdx = filtered.indexWhere((e) => e.id == currentId);
                if (selIdx > 0) {
                  final sel = filtered.removeAt(selIdx);
                  filtered.insert(0, sel);
                }
                return UISheetSurface(
                  child: Column(
                    children: [
                      const SizedBox(height: AppTheme.spacing3),
                      const UISheetHandle(),
                      const SizedBox(height: AppTheme.spacing3),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: SearchTextField(
                          controller: queryCtrl,
                          hintText: AppLocalizations.of(
                            context,
                          ).searchProviderPlaceholder,
                          autofocus: true,
                          onChanged: (_) {
                            _segProviderQueryText = queryCtrl.text;
                            setModalState(() {});
                          },
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          controller: scrollCtrl,
                          itemCount: filtered.length,
                          separatorBuilder: (c, i) => Container(
                            height: 1,
                            color: Theme.of(
                              c,
                            ).colorScheme.outline.withOpacity(0.6),
                          ),
                          itemBuilder: (c, i) {
                            final p = filtered[i];
                            final selected = p.id == currentId;
                            return ListTile(
                              leading: ProviderLogo(
                                providerType: p.type,
                                providerName: p.name,
                                baseUrl: p.baseUrl,
                                size: 20,
                              ),
                              title: Text(
                                p.name,
                                style: Theme.of(c).textTheme.bodyMedium,
                              ),
                              trailing: selected
                                  ? Icon(
                                      Icons.check_circle,
                                      color: Theme.of(c).colorScheme.onSurface,
                                    )
                                  : null,
                              onTap: () async {
                                String model = (_ctxSegModel ?? '').trim();
                                if (model.isEmpty) {
                                  model =
                                      (p.extra['active_model'] as String? ??
                                              p.defaultModel)
                                          .toString()
                                          .trim();
                                }
                                if (model.isEmpty && p.models.isNotEmpty)
                                  model = p.models.first;
                                await AISettingsService.instance
                                    .setAIContextSelection(
                                      context: 'segments',
                                      providerId: p.id!,
                                      model: model,
                                    );
                                if (mounted) {
                                  _segmentStatusSetState(() {
                                    _ctxSegProvider = p;
                                    _ctxSegModel = model;
                                  });
                                  Navigator.of(ctx).pop();
                                  UINotifier.success(
                                    context,
                                    AppLocalizations.of(
                                      context,
                                    ).providerSelectedToast(p.name),
                                  );
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _showModelSheetSegments() async {
    final p = _ctxSegProvider;
    if (p == null) {
      UINotifier.info(
        context,
        AppLocalizations.of(context).pleaseSelectProviderFirst,
      );
      return;
    }
    final models = p.models;
    if (models.isEmpty) {
      UINotifier.info(
        context,
        AppLocalizations.of(context).noModelsForProviderHint,
      );
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final active = (_ctxSegModel ?? '').trim();
        // 使用持久化查询文本，避免失焦时文本被清空
        final TextEditingController queryCtrl = TextEditingController(
          text: _segModelQueryText,
        );
        return StatefulBuilder(
          builder: (c, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.85,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (_, scrollCtrl) {
                final q = queryCtrl.text.trim().toLowerCase();
                final filtered = models.where((mm) {
                  if (q.isEmpty) return true;
                  return mm.toLowerCase().contains(q);
                }).toList();
                // 将当前选中的模型置顶
                if (active.isNotEmpty && filtered.contains(active)) {
                  final idx = filtered.indexOf(active);
                  if (idx > 0) {
                    final sel = filtered.removeAt(idx);
                    filtered.insert(0, sel);
                  }
                }
                return UISheetSurface(
                  child: Column(
                    children: [
                      const SizedBox(height: AppTheme.spacing3),
                      const UISheetHandle(),
                      const SizedBox(height: AppTheme.spacing3),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: SearchTextField(
                          controller: queryCtrl,
                          hintText: AppLocalizations.of(
                            context,
                          ).searchModelPlaceholder,
                          autofocus: true,
                          onChanged: (_) {
                            _segModelQueryText = queryCtrl.text;
                            setModalState(() {});
                          },
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          controller: scrollCtrl,
                          itemCount: filtered.length,
                          separatorBuilder: (c, i) => Container(
                            height: 1,
                            color: Theme.of(
                              c,
                            ).colorScheme.outline.withOpacity(0.6),
                          ),
                          itemBuilder: (c, i) {
                            final m = filtered[i];
                            final selected = m == active;
                            return ListTile(
                              leading: ModelLogo(modelId: m, size: 20),
                              title: Text(
                                m,
                                style: Theme.of(c).textTheme.bodyMedium,
                              ),
                              trailing: selected
                                  ? Icon(
                                      Icons.check_circle,
                                      color: Theme.of(c).colorScheme.primary,
                                    )
                                  : null,
                              onTap: () async {
                                await AISettingsService.instance
                                    .setAIContextSelection(
                                      context: 'segments',
                                      providerId: p.id!,
                                      model: m,
                                    );
                                if (mounted) {
                                  _segmentStatusSetState(
                                    () => _ctxSegModel = m,
                                  );
                                  Navigator.of(ctx).pop();
                                  UINotifier.success(
                                    context,
                                    AppLocalizations.of(
                                      context,
                                    ).modelSwitchedToast(m),
                                  );
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// AppBar 顶部：仅显示内容并加下划线（provider / model），不显示“提供商”字样
  Widget _buildSegmentsProviderModelAppBarTitle() {
    final theme = Theme.of(context);
    final String providerName = _ctxSegProvider?.name ?? '—';
    final String modelName = _ctxSegModel ?? '—';
    final TextStyle? linkStyle = theme.textTheme.labelSmall?.copyWith(
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.onSurface.withOpacity(0.6),
      color: theme.colorScheme.onSurface,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (modelName.trim().isNotEmpty && modelName != '—') ...[
          ModelLogo(modelId: modelName, size: 18),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: GestureDetector(
            onTap: _showProviderSheetSegments,
            behavior: HitTestBehavior.opaque,
            child: Text(
              providerName,
              style: linkStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: GestureDetector(
            onTap: _showModelSheetSegments,
            behavior: HitTestBehavior.opaque,
            child: Text(
              modelName,
              style: linkStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}
