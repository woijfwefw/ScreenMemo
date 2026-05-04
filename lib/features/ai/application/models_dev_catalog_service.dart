import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:screen_memo/core/logging/flutter_logger.dart';
import 'package:screen_memo/features/ai/application/ai_model_prompt_caps_service.dart';

/// models.dev 中的提供商信息。
class ModelsDevProviderInfo {
  const ModelsDevProviderInfo({
    required this.id,
    required this.name,
    required this.npm,
    required this.api,
    required this.doc,
    required this.env,
    required this.models,
  });

  final String id;
  final String name;
  final String npm;
  final String api;
  final String doc;
  final List<String> env;
  final Map<String, ModelsDevModelInfo> models;
}

/// models.dev 中的模型信息。
class ModelsDevModelInfo {
  const ModelsDevModelInfo({
    required this.providerId,
    required this.providerName,
    required this.id,
    required this.name,
    this.family,
    this.attachment,
    this.reasoning,
    this.toolCall,
    this.structuredOutput,
    this.temperature,
    this.knowledge,
    this.releaseDate,
    this.lastUpdated,
    this.openWeights,
    this.status,
    required this.inputModalities,
    required this.outputModalities,
    required this.cost,
    this.contextTokens,
    this.inputTokens,
    this.outputTokens,
  });

  final String providerId;
  final String providerName;
  final String id;
  final String name;
  final String? family;
  final bool? attachment;
  final bool? reasoning;
  final bool? toolCall;
  final bool? structuredOutput;
  final bool? temperature;
  final String? knowledge;
  final String? releaseDate;
  final String? lastUpdated;
  final bool? openWeights;
  final String? status;
  final List<String> inputModalities;
  final List<String> outputModalities;

  /// 每百万 token 价格，单位 USD。常见 key：input/output/cache_read/cache_write/reasoning。
  final Map<String, double> cost;

  /// 最大上下文窗口。
  final int? contextTokens;

  /// 最大输入 token；若存在，优先用于本项目 prompt budget。
  final int? inputTokens;

  /// 最大输出 token。
  final int? outputTokens;

  /// 本项目用于 prompt budget 的上限：优先 input，其次 context-output，最后 context。
  int? get promptCapTokens {
    final int? input = inputTokens;
    if (input != null && input > 0) return input;
    final int? context = contextTokens;
    final int? output = outputTokens;
    if (context != null && context > 0 && output != null && output > 0) {
      final int prompt = context - output;
      if (prompt > 0) return prompt;
    }
    if (context != null && context > 0) return context;
    return null;
  }
}

/// models.dev 远程目录服务。
///
/// 用途：
/// - 使用 https://models.dev/api.json 解析模型上下文、输出、价格和能力；
/// - Logo 渲染不走远程接口，仍由本地素材匹配；
/// - 在刷新模型列表时把 prompt 上限写入本地 override，避免未知模型落到默认值。
class ModelsDevCatalogService {
  ModelsDevCatalogService._();

  static final ModelsDevCatalogService instance = ModelsDevCatalogService._();

  static const String apiUrl = 'https://models.dev/api.json';

  Future<Map<String, ModelsDevProviderInfo>>? _loadFuture;
  Map<String, ModelsDevProviderInfo>? _providers;
  Map<String, List<ModelsDevModelInfo>> _modelIndex =
      <String, List<ModelsDevModelInfo>>{};

  /// 由本项目 provider type 映射 models.dev provider id。
  static String providerIdForType(String? type) {
    switch ((type ?? '').trim().toLowerCase()) {
      case 'openai':
      case 'azure_openai':
      case 'azure':
        return 'openai';
      case 'claude':
      case 'anthropic':
        return 'anthropic';
      case 'gemini':
      case 'google':
        return 'google';
      default:
        return '';
    }
  }

  /// 不依赖网络的模型名启发式 provider id，用于首屏 Logo 兜底。
  static String inferProviderIdFromModel(String? model) {
    final inferred = _inferProviderIdFromModelStrict(model);
    if (inferred.isNotEmpty) return inferred;
    return 'openai';
  }

  /// 不带默认值的 provider 推断，用于模型目录匹配时作为辅助 hint。
  static String _inferProviderIdFromModelStrict(String? model) {
    String m = (model ?? '').trim().toLowerCase();
    if (m.isEmpty) return '';
    if (m.startsWith('models/')) m = m.substring('models/'.length);

    final int slash = m.indexOf('/');
    if (slash > 0) {
      final prefix = _sanitizeProviderId(m.substring(0, slash));
      if (prefix.isNotEmpty && prefix != 'hf') return prefix;
      if (prefix == 'hf') return 'huggingface';
    }

    if (m.contains('claude') || m.contains('anthropic')) return 'anthropic';
    if (m.contains('gemini') || m.contains('gemma')) return 'google';
    if (m.contains('deepseek')) return 'deepseek';
    if (m.contains('qwen') || m.contains('dashscope')) return 'alibaba';
    if (m.contains('kimi') || m.contains('moonshot')) return 'moonshot';
    if (m.contains('grok') || m.contains('xai')) return 'xai';
    if (m.contains('mistral') || m.contains('mixtral')) return 'mistral';
    if (m.contains('llama') || m.contains('meta')) return 'meta';
    if (m.contains('sonar') || m.contains('perplexity')) return 'perplexity';
    if (m.contains('gpt') || m.contains('openai') || m.contains('o1')) {
      return 'openai';
    }
    if (m.contains('o3') || m.contains('o4')) return 'openai';
    if (m.contains('groq')) return 'groq';
    if (m.contains('cohere') || m.contains('command')) return 'cohere';
    if (m.contains('minimax')) return 'minimax';
    if (m.contains('doubao') || m.contains('seed')) return 'bytedance';
    return '';
  }

  /// 从常见 API 域名推断 provider id。只做轻量启发式，找不到则返回空串。
  static String inferProviderIdFromUrl(String? url) {
    final raw = (url ?? '').trim().toLowerCase();
    if (raw.isEmpty) return '';
    Uri? uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      uri = Uri.tryParse('https://$raw');
    }
    final host = (uri?.host ?? raw).toLowerCase();
    if (host.contains('anthropic')) return 'anthropic';
    if (host.contains('generativelanguage') || host.contains('google')) {
      return 'google';
    }
    if (host.contains('openai.azure') || host.contains('openai')) {
      return 'openai';
    }
    if (host.contains('deepseek')) return 'deepseek';
    if (host.contains('aliyun') || host.contains('dashscope')) {
      return 'alibaba';
    }
    if (host.contains('moonshot') || host.contains('kimi')) return 'moonshot';
    if (host.contains('x.ai')) return 'xai';
    if (host.contains('mistral')) return 'mistral';
    if (host.contains('openrouter')) return 'openrouter';
    if (host.contains('perplexity')) return 'perplexity';
    if (host.contains('groq')) return 'groq';
    if (host.contains('cohere')) return 'cohere';
    if (host.contains('minimax')) return 'minimax';
    if (host.contains('volces') || host.contains('doubao')) return 'bytedance';
    return '';
  }

  Future<void> preload() async {
    await _loadProviders();
  }

  Future<Map<String, ModelsDevProviderInfo>> _loadProviders() {
    final cached = _providers;
    if (cached != null) return Future.value(cached);
    final loading = _loadFuture;
    if (loading != null) return loading;
    final future = _fetchProviders();
    _loadFuture = future;
    return future;
  }

  Future<Map<String, ModelsDevProviderInfo>> _fetchProviders() async {
    try {
      final response = await http
          .get(
            Uri.parse(apiUrl),
            headers: const <String, String>{
              'User-Agent': 'ScreenMemo models.dev catalog client',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'models.dev request failed: ${response.statusCode} ${response.body}',
        );
      }

      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map) return const <String, ModelsDevProviderInfo>{};

      final providers = <String, ModelsDevProviderInfo>{};
      final index = <String, List<ModelsDevModelInfo>>{};

      for (final entry in decoded.entries) {
        final providerId = _sanitizeProviderId('${entry.key}');
        final rawProvider = entry.value;
        if (providerId.isEmpty || rawProvider is! Map) continue;
        final providerName = _stringValue(rawProvider['name']).isEmpty
            ? providerId
            : _stringValue(rawProvider['name']);
        final rawModels = rawProvider['models'];
        final models = <String, ModelsDevModelInfo>{};

        if (rawModels is Map) {
          for (final modelEntry in rawModels.entries) {
            final rawModel = modelEntry.value;
            if (rawModel is! Map) continue;
            final model = _parseModel(
              providerId: providerId,
              providerName: providerName,
              fallbackId: '${modelEntry.key}',
              raw: rawModel,
            );
            models[model.id] = model;
            _addModelIndex(index, model);
          }
        }

        providers[providerId] = ModelsDevProviderInfo(
          id: providerId,
          name: providerName,
          npm: _stringValue(rawProvider['npm']),
          api: _stringValue(rawProvider['api']),
          doc: _stringValue(rawProvider['doc']),
          env: _stringList(rawProvider['env']),
          models: models,
        );
      }

      _providers = providers;
      _modelIndex = index;
      return providers;
    } catch (e) {
      _loadFuture = null;
      try {
        await FlutterLogger.nativeWarn(
          'AI',
          'models.dev catalog load failed: $e',
        );
      } catch (_) {}
      return const <String, ModelsDevProviderInfo>{};
    }
  }

  static ModelsDevModelInfo _parseModel({
    required String providerId,
    required String providerName,
    required String fallbackId,
    required Map raw,
  }) {
    final limit = raw['limit'] is Map ? raw['limit'] as Map : const {};
    final modalities = raw['modalities'] is Map
        ? raw['modalities'] as Map
        : const {};
    final cost = raw['cost'] is Map ? raw['cost'] as Map : const {};
    return ModelsDevModelInfo(
      providerId: providerId,
      providerName: providerName,
      id: _stringValue(raw['id']).isEmpty
          ? fallbackId
          : _stringValue(raw['id']),
      name: _stringValue(raw['name']).isEmpty
          ? fallbackId
          : _stringValue(raw['name']),
      family: _nullableString(raw['family']),
      attachment: _boolValue(raw['attachment']),
      reasoning: _boolValue(raw['reasoning']),
      toolCall: _boolValue(raw['tool_call']),
      structuredOutput: _boolValue(raw['structured_output']),
      temperature: _boolValue(raw['temperature']),
      knowledge: _nullableString(raw['knowledge']),
      releaseDate: _nullableString(raw['release_date']),
      lastUpdated: _nullableString(raw['last_updated']),
      openWeights: _boolValue(raw['open_weights']),
      status: _nullableString(raw['status']),
      inputModalities: _stringList(modalities['input']),
      outputModalities: _stringList(modalities['output']),
      cost: _doubleMap(cost),
      contextTokens: _intValue(limit['context']),
      inputTokens: _intValue(limit['input']),
      outputTokens: _intValue(limit['output']),
    );
  }

  Future<ModelsDevModelInfo?> findModel(
    String model, {
    String? providerTypeHint,
    String? providerBaseUrl,
    String? providerName,
  }) async {
    await _loadProviders();
    return peekModel(
      model,
      providerTypeHint: providerTypeHint,
      providerBaseUrl: providerBaseUrl,
      providerName: providerName,
    );
  }

  ModelsDevModelInfo? peekModel(
    String model, {
    String? providerTypeHint,
    String? providerBaseUrl,
    String? providerName,
  }) {
    final providerHint = _providerHint(
      providerTypeHint: providerTypeHint,
      providerBaseUrl: providerBaseUrl,
      providerName: providerName,
    );
    final providerHints = _providerHintsForModel(model, providerHint);
    final lookupKeys = _modelLookupKeys(model);
    for (final key in lookupKeys) {
      final match = _bestMatch(_modelIndex[key], providerHints);
      if (match != null) return match;
    }
    return _prefixMatch(lookupKeys, providerHints);
  }

  Future<Map<String, ModelsDevModelInfo>> findModels(
    Iterable<String> models, {
    String? providerTypeHint,
    String? providerBaseUrl,
    String? providerName,
  }) async {
    await _loadProviders();
    final out = <String, ModelsDevModelInfo>{};
    for (final model in models) {
      final name = model.trim();
      if (name.isEmpty) continue;
      final info = peekModel(
        name,
        providerTypeHint: providerTypeHint,
        providerBaseUrl: providerBaseUrl,
        providerName: providerName,
      );
      if (info != null) out[name.toLowerCase()] = info;
    }
    return out;
  }

  /// 将 models.dev 中的 prompt cap 写入本地 override。
  ///
  /// 失败不抛出，避免影响原来的模型列表刷新流程。
  Future<int> cachePromptCapsForModels(
    Iterable<String> models, {
    String? providerTypeHint,
    String? providerBaseUrl,
    String? providerName,
  }) async {
    try {
      final meta = await findModels(
        models,
        providerTypeHint: providerTypeHint,
        providerBaseUrl: providerBaseUrl,
        providerName: providerName,
      );
      int updated = 0;
      for (final entry in meta.entries) {
        final int? cap = entry.value.promptCapTokens;
        if (cap == null || cap <= 0) continue;
        await AIModelPromptCapsService.instance.setOverride(entry.key, cap);
        // 同时用原始模型 id 写一份，便于后续用 provider/model 形式匹配。
        if (entry.value.id.toLowerCase() != entry.key) {
          await AIModelPromptCapsService.instance.setOverride(
            entry.value.id,
            cap,
          );
        }
        updated++;
      }
      return updated;
    } catch (e) {
      try {
        await FlutterLogger.nativeWarn(
          'AI',
          'models.dev prompt cap cache failed: $e',
        );
      } catch (_) {}
      return 0;
    }
  }

  static String _providerHint({
    String? providerTypeHint,
    String? providerBaseUrl,
    String? providerName,
  }) {
    final byType = providerIdForType(providerTypeHint);
    if (byType.isNotEmpty) return byType;
    final byUrl = inferProviderIdFromUrl(providerBaseUrl);
    if (byUrl.isNotEmpty) return byUrl;
    return _sanitizeProviderId(providerName ?? '');
  }

  static List<String> _providerHintsForModel(
    String model,
    String providerHint,
  ) {
    final seen = <String>{};
    final hints = <String>[];

    void add(String value) {
      final hint = _sanitizeProviderId(value);
      if (hint.isEmpty) return;
      if (seen.add(hint)) hints.add(hint);
    }

    add(providerHint);
    add(_inferProviderIdFromModelStrict(model));
    return hints;
  }

  ModelsDevModelInfo? _prefixMatch(
    List<String> lookupKeys,
    List<String> providerHints,
  ) {
    ModelsDevModelInfo? best;
    int bestKeyLength = -1;
    int bestProviderRank = 1 << 20;

    for (final queryKey in lookupKeys) {
      for (final entry in _modelIndex.entries) {
        final candidateKey = entry.key;
        if (!_isModelVariantKey(queryKey, candidateKey)) continue;
        final match = _bestMatch(entry.value, providerHints);
        if (match == null) continue;
        final providerRank = _providerRank(match.providerId, providerHints);
        if (providerRank < bestProviderRank ||
            (providerRank == bestProviderRank &&
                candidateKey.length > bestKeyLength)) {
          best = match;
          bestKeyLength = candidateKey.length;
          bestProviderRank = providerRank;
        }
      }
    }
    return best;
  }

  static ModelsDevModelInfo? _bestMatch(
    List<ModelsDevModelInfo>? candidates,
    List<String> providerHints,
  ) {
    if (candidates == null || candidates.isEmpty) return null;
    for (final providerHint in providerHints) {
      for (final item in candidates) {
        if (item.providerId == providerHint) return item;
      }
    }
    return candidates.first;
  }

  static int _providerRank(String providerId, List<String> providerHints) {
    final normalized = _sanitizeProviderId(providerId);
    final index = providerHints.indexOf(normalized);
    return index < 0 ? 1 << 20 : index;
  }

  static bool _isModelVariantKey(String queryKey, String candidateKey) {
    if (queryKey.length <= candidateKey.length) return false;
    if (!_looksSpecificEnoughForVariantMatch(candidateKey)) return false;
    if (!queryKey.startsWith(candidateKey)) return false;
    final next = queryKey[candidateKey.length];
    return next == '-' ||
        next == '_' ||
        next == '.' ||
        next == ':' ||
        next == '/';
  }

  static bool _looksSpecificEnoughForVariantMatch(String key) {
    if (key.length < 6) return false;
    if (RegExp(r'\d').hasMatch(key)) return true;
    return key.length >= 10 && key.contains('-');
  }

  static void _addModelIndex(
    Map<String, List<ModelsDevModelInfo>> index,
    ModelsDevModelInfo model,
  ) {
    final rawValues = <String>{
      model.id,
      model.name,
      '${model.providerId}/${model.id}',
      _dequalifyModel(model.id),
      _canonicalizeModel(model.id),
      _dequalifyModel(_canonicalizeModel(model.id)),
    };
    final addedKeys = <String>{};
    for (final value in rawValues) {
      for (final expanded in _expandedModelKeyValues(value)) {
        final key = _normalizeModelKey(expanded);
        if (key.isEmpty) continue;
        if (!addedKeys.add(key)) continue;
        final list = index.putIfAbsent(key, () => <ModelsDevModelInfo>[]);
        list.add(model);
      }
    }
  }

  static List<String> _modelLookupKeys(String model) {
    final normalized = model.trim();
    final values = <String>[
      normalized,
      normalized.startsWith('models/')
          ? normalized.substring('models/'.length)
          : normalized,
      _dequalifyModel(normalized),
      _canonicalizeModel(normalized),
      _dequalifyModel(_canonicalizeModel(normalized)),
    ];
    final seen = <String>{};
    final out = <String>[];
    for (final value in values) {
      for (final expanded in _expandedModelKeyValues(value)) {
        final key = _normalizeModelKey(expanded);
        if (key.isEmpty) continue;
        if (seen.add(key)) out.add(key);
      }
    }
    return out;
  }

  static Iterable<String> _expandedModelKeyValues(String value) sync* {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    yield trimmed;

    final folded = _foldModelSeparators(trimmed);
    if (folded != trimmed) yield folded;

    for (final alias in _knownModelAliasValues(trimmed)) {
      if (alias.isEmpty) continue;
      yield alias;
      final foldedAlias = _foldModelSeparators(alias);
      if (foldedAlias != alias) yield foldedAlias;
    }
  }

  static Iterable<String> _knownModelAliasValues(String value) sync* {
    final claude = _claudeVersionFamilyAlias(value);
    if (claude != null && claude.isNotEmpty) yield claude;
  }

  /// 兼容部分中转站把 Claude 写成 claude-4.6-sonnet-real 的顺序。
  ///
  /// models.dev / Anthropic 官方模型为 claude-sonnet-4-6，所以这里把
  /// claude-{version}-{family}-{suffix} 归一到 claude-{family}-{version}-{suffix}，
  /// 后续再走安全前缀兜底。
  static String? _claudeVersionFamilyAlias(String value) {
    final canonical = _dequalifyModel(_canonicalizeModel(value));
    final folded = _foldModelSeparators(canonical).toLowerCase();
    final parts = RegExp(r'[a-z0-9]+')
        .allMatches(folded)
        .map((match) => match.group(0) ?? '')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 4 || parts.first != 'claude') return null;

    const families = <String>{'sonnet', 'opus', 'haiku'};
    for (int i = 2; i < parts.length; i++) {
      final family = parts[i];
      if (!families.contains(family)) continue;
      final versionParts = parts.sublist(1, i);
      if (versionParts.isEmpty) continue;
      if (!versionParts.every((part) => RegExp(r'^\d+$').hasMatch(part))) {
        continue;
      }
      final reordered = <String>[
        'claude',
        family,
        ...versionParts,
        ...parts.sublist(i + 1),
      ];
      return reordered.join('-');
    }
    return null;
  }

  static String _foldModelSeparators(String value) {
    String s = value.trim();
    if (s.isEmpty) return s;
    s = s.replaceAll(RegExp(r'[._]+'), '-');
    s = s.replaceAll(RegExp(r'-{2,}'), '-');
    return s;
  }

  static String _normalizeModelKey(String value) {
    String s = value.trim().toLowerCase();
    if (s.startsWith('models/')) s = s.substring('models/'.length);
    return s;
  }

  static String _canonicalizeModel(String model) {
    final value = model.trim();
    final int slash = value.lastIndexOf('/');
    if (slash < 0 || slash + 1 >= value.length) return value;
    return value.substring(slash + 1).trim();
  }

  static String _dequalifyModel(String model) {
    String value = model.trim();
    final int query = value.indexOf('?');
    if (query > 0) value = value.substring(0, query).trim();
    final int hash = value.indexOf('#');
    if (hash > 0) value = value.substring(0, hash).trim();
    final int slash = value.lastIndexOf('/');
    final int colon = value.lastIndexOf(':');
    if (colon > 0 && colon > slash) {
      value = value.substring(0, colon).trim();
    }
    return value;
  }

  static String _sanitizeProviderId(String value) {
    String id = value.trim().toLowerCase();
    id = id.replaceAll(RegExp(r'[^a-z0-9\-_]+'), '-');
    id = id.replaceAll(RegExp(r'-{2,}'), '-');
    id = id.replaceAll(RegExp(r'^-+|-+$'), '');
    return id;
  }

  static String _stringValue(Object? value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  static String? _nullableString(Object? value) {
    final s = _stringValue(value);
    return s.isEmpty ? null : s;
  }

  static bool? _boolValue(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final v = value.trim().toLowerCase();
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return null;
  }

  static int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    final raw = value?.toString().replaceAll('_', '').trim();
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static Map<String, double> _doubleMap(Map raw) {
    final out = <String, double>{};
    for (final entry in raw.entries) {
      final key = _stringValue(entry.key);
      if (key.isEmpty) continue;
      final value = entry.value;
      double? parsed;
      if (value is num) {
        parsed = value.toDouble();
      } else {
        parsed = double.tryParse(value?.toString() ?? '');
      }
      if (parsed != null) out[key] = parsed;
    }
    return out;
  }
}
