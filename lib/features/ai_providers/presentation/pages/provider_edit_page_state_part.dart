part of 'provider_edit_page.dart';

extension _ProviderEditStatePart on _ProviderEditPageState {
  List<String> _aggregateKeyModels(List<AIProviderKey> keys) {
    final seen = <String>{};
    final out = <String>[];
    for (final key in keys.where((k) => k.enabled)) {
      for (final model in key.models) {
        final m = model.trim();
        if (m.isEmpty) continue;
        if (seen.add(m.toLowerCase())) out.add(m);
      }
    }
    return out;
  }

  Future<void> _reloadKeys() async {
    final id = _loaded?.id;
    if (id == null) return;
    unawaited(_logKeyFlow('edit.reload_keys.start provider=$id'));
    final keys = await _svc.listProviderKeys(id);
    if (!mounted) return;
    _providerEditSetState(() {
      _keys = keys;
      _models = _aggregateKeyModels(keys);
    });
    unawaited(
      _logKeyFlow(
        'edit.reload_keys.done provider=$id keyCount=${keys.length} models=${_models.length} keys=${_debugKeyList(keys)}',
      ),
    );
    unawaited(_loadModelMetadataFor(_models));
  }

  Future<void> _loadModelMetadataFor(List<String> models) async {
    final int seq = ++_modelInfoLoadSeq;
    final List<String> target = List<String>.from(models);
    if (target.isEmpty) {
      if (!mounted || seq != _modelInfoLoadSeq) return;
      _providerEditSetState(() => _modelInfoByName.clear());
      return;
    }
    final Map<String, ModelsDevModelInfo> info = await _modelsDev.findModels(
      target,
      providerTypeHint: _type,
      providerBaseUrl: _baseUrlCtrl.text,
      providerName: _nameCtrl.text,
    );
    // 手动添加模型时也顺带把可解析到的上下文写入本地 prompt cap override。
    unawaited(
      _modelsDev.cachePromptCapsForModels(
        target,
        providerTypeHint: _type,
        providerBaseUrl: _baseUrlCtrl.text,
        providerName: _nameCtrl.text,
      ),
    );
    if (!mounted || seq != _modelInfoLoadSeq) return;
    _providerEditSetState(() {
      _modelInfoByName
        ..clear()
        ..addAll(info);
    });
  }

  List<ProviderHeaderEntry> _headerEntriesFromDrafts() {
    return ProviderRequestHeaders.normalizeEntries(
      _headerDrafts.map((_HeaderDraft draft) => draft.toEntry()),
    );
  }

  List<AIProviderKey> get _displayKeys {
    if (_keys.length <= 1) return List<AIProviderKey>.from(_keys);
    final list = List<AIProviderKey>.from(_keys);
    switch (_keySortMode) {
      case _ProviderKeySortMode.runtime:
        return list;
      case _ProviderKeySortMode.successDesc:
        list.sort((a, b) {
          final int success = b.successCount.compareTo(a.successCount);
          if (success != 0) return success;
          final int last = (b.lastSuccessAt ?? 0).compareTo(
            a.lastSuccessAt ?? 0,
          );
          if (last != 0) return last;
          return _compareDefaultKeyOrder(a, b);
        });
        return list;
      case _ProviderKeySortMode.recentSuccessDesc:
        list.sort((a, b) {
          final int last = (b.lastSuccessAt ?? 0).compareTo(
            a.lastSuccessAt ?? 0,
          );
          if (last != 0) return last;
          final int success = b.successCount.compareTo(a.successCount);
          if (success != 0) return success;
          return _compareDefaultKeyOrder(a, b);
        });
        return list;
      case _ProviderKeySortMode.failureDesc:
        list.sort((a, b) {
          final int failure = b.failureTotalCount.compareTo(
            a.failureTotalCount,
          );
          if (failure != 0) return failure;
          final int last = (b.lastFailedAt ?? 0).compareTo(a.lastFailedAt ?? 0);
          if (last != 0) return last;
          return _compareDefaultKeyOrder(a, b);
        });
        return list;
      case _ProviderKeySortMode.continuousFailureDesc:
        list.sort((a, b) {
          final int failure = b.failureCount.compareTo(a.failureCount);
          if (failure != 0) return failure;
          final int last = (b.lastFailedAt ?? 0).compareTo(a.lastFailedAt ?? 0);
          if (last != 0) return last;
          return _compareDefaultKeyOrder(a, b);
        });
        return list;
      case _ProviderKeySortMode.newestDesc:
        list.sort((a, b) {
          final int newest = (b.id ?? 0).compareTo(a.id ?? 0);
          if (newest != 0) return newest;
          return _compareDefaultKeyOrder(a, b);
        });
        return list;
    }
  }

  int _compareDefaultKeyOrder(AIProviderKey a, AIProviderKey b) {
    final int enabled = (b.enabled ? 1 : 0).compareTo(a.enabled ? 1 : 0);
    if (enabled != 0) return enabled;
    final int priority = a.priority.compareTo(b.priority);
    if (priority != 0) return priority;
    final int order = a.orderIndex.compareTo(b.orderIndex);
    if (order != 0) return order;
    return (a.id ?? 0).compareTo(b.id ?? 0);
  }

  String _keySortModeLabel(_ProviderKeySortMode mode) {
    switch (mode) {
      case _ProviderKeySortMode.runtime:
        return '默认顺序';
      case _ProviderKeySortMode.successDesc:
        return '成功次数';
      case _ProviderKeySortMode.recentSuccessDesc:
        return '最近成功';
      case _ProviderKeySortMode.failureDesc:
        return '失败总数';
      case _ProviderKeySortMode.continuousFailureDesc:
        return '连续失败';
      case _ProviderKeySortMode.newestDesc:
        return '最新添加';
    }
  }

  AIProvider? _currentProviderSnapshot() {
    final int? providerId = _loaded?.id;
    if (providerId == null) return null;
    final String base = _baseUrlCtrl.text.trim();
    return AIProvider(
      id: providerId,
      name: _nameCtrl.text.trim().isEmpty
          ? (_loaded?.name ?? 'Provider')
          : _nameCtrl.text.trim(),
      type: _type,
      baseUrl: base.isEmpty ? null : base,
      chatPath: _chatPathCtrl.text.trim().isEmpty
          ? null
          : _chatPathCtrl.text.trim(),
      modelsPath: _effectiveModelsPath(),
      useResponseApi: _useResponseApi,
      enabled: true,
      isDefault: false,
      models: List<String>.from(_models),
      extra: _buildExtra(),
      orderIndex: _loaded?.orderIndex ?? 0,
    );
  }

  String _clipDialogText(String value, [int max = 240]) {
    final String text = value.trim();
    if (text.length <= max) return text;
    return '${text.substring(0, max)}...';
  }

  void _applyTypeDefaults(String t, {bool initial = false}) {
    _type = t;
    String? baseDefault;
    switch (t) {
      case AIProviderTypes.openai:
        baseDefault = 'https://api.openai.com';
        break;
      case AIProviderTypes.claude:
        baseDefault = 'https://api.anthropic.com';
        break;
      case AIProviderTypes.gemini:
        baseDefault = 'https://generativelanguage.googleapis.com';
        _showGeminiRegionNotice();
        break;
      case AIProviderTypes.azureOpenAI:
        baseDefault = '';
        break;
      case AIProviderTypes.custom:
        baseDefault = '';
        break;
    }
    if (initial) {
      _baseUrlCtrl.text = baseDefault ?? '';
    } else {
      final cur = _baseUrlCtrl.text.trim();
      if (cur.isEmpty ||
          cur == 'https://api.openai.com' ||
          cur == 'https://api.anthropic.com' ||
          cur == 'https://generativelanguage.googleapis.com') {
        _baseUrlCtrl.text = baseDefault ?? '';
      }
    }
    final defaultModelsPath = defaultModelsPathForType(t);
    if (defaultModelsPath.isEmpty) {
      _modelsPathCtrl.clear();
    } else {
      _modelsPathCtrl.text = defaultModelsPath;
    }
    if (t != AIProviderTypes.openai && t != AIProviderTypes.custom) {
      _useResponseApi = false;
    }
    _chatPathCtrl.text = defaultChatPathForType(
      t,
      useResponsesApi: _useResponseApi,
    );
    _models = <String>[];
    _modelInfoByName.clear();
  }

  void _addHeaderDraft() {
    _providerEditSetState(() {
      _headerDrafts = <_HeaderDraft>[..._headerDrafts, _HeaderDraft()];
    });
  }

  void _removeHeaderDraft(int index) {
    if (index < 0 || index >= _headerDrafts.length) return;
    _providerEditSetState(() {
      final List<_HeaderDraft> next = List<_HeaderDraft>.from(_headerDrafts);
      final _HeaderDraft removed = next.removeAt(index);
      removed.dispose();
      _headerDrafts = next;
    });
  }

  void _applyHeaderTemplate(ProviderHeaderTemplate template) {
    _providerEditSetState(() {
      for (final _HeaderDraft draft in _headerDrafts) {
        draft.dispose();
      }
      _headerDrafts = template.entries
          .map(_HeaderDraft.fromEntry)
          .toList(growable: false);
      _requestBodyStyle = template.bodyStyle;
      if (template.bodyStyle == ProviderRequestBodyStyles.codexResponses) {
        _useResponseApi = true;
        _chatPathCtrl.text = '/v1/responses';
      } else if (template.bodyStyle ==
          ProviderRequestBodyStyles.anthropicMessages) {
        _useResponseApi = false;
        _chatPathCtrl.text = '/v1/messages';
      } else if (template.bodyStyle ==
          ProviderRequestBodyStyles.claudeCodeMessages) {
        _useResponseApi = false;
        _chatPathCtrl.text = '/v1/messages?beta=true';
      }
    });
  }

  bool get _supportsModelsPath {
    return _type == AIProviderTypes.openai ||
        _type == AIProviderTypes.custom ||
        _type == AIProviderTypes.claude ||
        _type == AIProviderTypes.gemini;
  }

  String _effectiveModelsPath() {
    if (!_supportsModelsPath) return '';
    final raw = _modelsPathCtrl.text.trim();
    if (raw.isNotEmpty) return raw;
    final def = defaultModelsPathForType(_type);
    return def.isNotEmpty ? def : '/v1/models';
  }

  String _baseUrlHint() {
    switch (_type) {
      case AIProviderTypes.openai:
        return AppLocalizations.of(context).baseUrlHintOpenAI;
      case AIProviderTypes.claude:
        return AppLocalizations.of(context).baseUrlHintClaude;
      case AIProviderTypes.gemini:
        return AppLocalizations.of(context).baseUrlHintGemini;
      case AIProviderTypes.azureOpenAI:
        return AppLocalizations.of(context).baseUrlHintAzure('{resource}');
      case AIProviderTypes.custom:
        return AppLocalizations.of(context).baseUrlHintCustom;
      default:
        return 'Base URL';
    }
  }

  Future<void> _refreshModels() async {
    if (_fetching) return;
    final providerId = _loaded?.id;
    if (providerId == null) {
      UINotifier.warning(
        context,
        AppLocalizations.of(context).providerSaveBeforeRefreshingModels,
      );
      return;
    }
    final AIProvider? provider = _currentProviderSnapshot();
    if (provider == null) return;
    final enabledKeys = _keys
        .where(
          (key) =>
              key.enabled && key.id != null && key.apiKey.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (enabledKeys.isEmpty) {
      UINotifier.error(
        context,
        AppLocalizations.of(context).providerAddAtLeastOneEnabledApiKey,
      );
      return;
    }
    final base = _baseUrlCtrl.text.trim();
    if ((_type == AIProviderTypes.azureOpenAI ||
            _type == AIProviderTypes.claude ||
            _type == AIProviderTypes.gemini ||
            _type == AIProviderTypes.custom) &&
        base.isEmpty) {
      UINotifier.error(
        context,
        AppLocalizations.of(context).baseUrlRequiredForAzureError,
      );
      return;
    }

    _providerEditSetState(() => _fetching = true);
    final List<String> fetchedModelPool = <String>[];
    int successCount = 0;
    final List<String> failureHints = <String>[];
    try {
      for (final key in enabledKeys) {
        try {
          final models = await _svc.refreshModelsForKey(
            providerId: providerId,
            keyId: key.id!,
            providerOverride: provider,
          );
          fetchedModelPool.addAll(models);
          successCount++;
        } catch (e) {
          failureHints.add(
            '${key.name}: ${_clipDialogText(e.toString(), 120)}',
          );
        }
      }
      await _reloadKeys();
      if (!mounted) return;
      if (successCount > 0) {
        final fetchedCount = _mergeModelNames(<Iterable<String>>[
          fetchedModelPool,
        ]).length;
        final failedHint = failureHints.isNotEmpty
            ? ', failed ${failureHints.length} keys'
            : '';
        UINotifier.success(
          context,
          'Model refresh complete: $successCount/${enabledKeys.length} keys, $fetchedCount models$failedHint',
        );
      } else {
        UINotifier.error(
          context,
          '${AppLocalizations.of(context).fetchModelsFailedHint} Failed keys: ${enabledKeys.length}',
        );
      }
      if (failureHints.isNotEmpty) {
        try {
          await FlutterLogger.nativeWarn(
            'AI',
            'refreshModels all-key failures provider=$providerId ${failureHints.join(' | ')}',
          );
        } catch (_) {}
      }
    } finally {
      if (mounted) _providerEditSetState(() => _fetching = false);
    }
  }

  Map<String, dynamic> _buildExtra() {
    final map = <String, dynamic>{...?_loaded?.extra};
    if (_type == AIProviderTypes.azureOpenAI) {
      map['azure_api_version'] = _azureApiVerCtrl.text.trim().isEmpty
          ? '2024-02-15'
          : _azureApiVerCtrl.text.trim();
    } else {
      map.remove('azure_api_version');
    }
    if (_models.isNotEmpty) {
      map['default_model'] = _models.first;
    } else {
      map.remove('default_model');
    }
    final Map<String, dynamic> withBodyStyle =
        ProviderRequestHeaders.writeBodyStyleToExtra(map, _requestBodyStyle);
    return ProviderRequestHeaders.writeEntriesToExtra(
      withBodyStyle,
      _headerEntriesFromDrafts(),
    );
  }
}
