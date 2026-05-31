// ignore_for_file: constant_identifier_names, unnecessary_null_in_if_null_operators

import 'dart:async';
import 'dart:convert';
import 'package:screen_memo/data/security/secure_storage_service.dart';
import 'package:http/http.dart' as http;

import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/core/logging/flutter_logger.dart';
import 'package:screen_memo/features/ai/application/models_dev_catalog_service.dart';
import 'package:screen_memo/features/ai/application/provider_request_headers.dart';

String defaultModelsPathForType(String type) {
  final normalized = type.trim().toLowerCase();
  switch (normalized) {
    case AIProviderTypes.openai:
    case AIProviderTypes.custom:
    case AIProviderTypes.claude:
      return '/v1/models';
    case AIProviderTypes.gemini:
      return '/v1beta/models';
    default:
      return '';
  }
}

String defaultChatPathForType(String type, {bool useResponsesApi = false}) {
  final normalized = type.trim().toLowerCase();
  switch (normalized) {
    case AIProviderTypes.openai:
    case AIProviderTypes.custom:
      return useResponsesApi ? '/v1/responses' : '/v1/chat/completions';
    case AIProviderTypes.claude:
      return '/v1/messages';
    case AIProviderTypes.gemini:
      return '/v1beta/{model=models/*}:generateContent';
    default:
      return '/v1/chat/completions';
  }
}

String? _normalizeModelsPathOrNull(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.startsWith('/')) return trimmed;
  return '/$trimmed';
}

String? _normalizeModelsPathForStorage(String? value) {
  final normalized = _normalizeModelsPathOrNull(value);
  if (normalized != null) return normalized;
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 提供商类型定义（与 UI 下拉一致）
class AIProviderTypes {
  static const String openai = 'openai';
  static const String azureOpenAI = 'azure_openai';
  static const String claude = 'claude';
  static const String gemini = 'gemini';
  static const String custom = 'custom';

  static const List<String> all = <String>[
    openai,
    azureOpenAI,
    claude,
    gemini,
    custom,
  ];
}

/// 提供商实体（来自 ai_providers 表 + 衍生字段）

class AIProviderKey {
  static const int defaultPriority = 100;

  final int? id;
  final int providerId;
  final String name;
  final String apiKey;
  final List<String> models;
  final bool enabled;
  final int priority;
  final int orderIndex;
  final int failureCount;
  final int successCount;
  final int failureTotalCount;
  final int? cooldownUntilMs;
  final String? lastErrorType;
  final String? lastErrorMessage;
  final int? lastFailedAt;
  final int? lastSuccessAt;

  const AIProviderKey({
    required this.id,
    required this.providerId,
    required this.name,
    required this.apiKey,
    required this.models,
    required this.enabled,
    required this.priority,
    required this.orderIndex,
    required this.failureCount,
    required this.successCount,
    required this.failureTotalCount,
    required this.cooldownUntilMs,
    required this.lastErrorType,
    required this.lastErrorMessage,
    required this.lastFailedAt,
    required this.lastSuccessAt,
  });

  factory AIProviderKey.fromDbRow(Map<String, dynamic> row) {
    final modelsJson = (row['models_json'] as String?) ?? '[]';
    List<String> parsedModels;
    try {
      final v = jsonDecode(modelsJson);
      parsedModels = v is List ? v.map((e) => '$e').toList() : <String>[];
    } catch (_) {
      parsedModels = <String>[];
    }
    return AIProviderKey(
      id: row['id'] as int?,
      providerId: (row['provider_id'] as int?) ?? 0,
      name: ((row['name'] as String?) ?? 'Key').trim(),
      apiKey: ((row['api_key'] as String?) ?? '').trim(),
      models: parsedModels,
      enabled: ((row['enabled'] as int?) ?? 1) != 0,
      priority: (row['priority'] as int?) ?? defaultPriority,
      orderIndex: (row['order_index'] as int?) ?? 0,
      failureCount: (row['failure_count'] as int?) ?? 0,
      successCount: (row['success_count'] as int?) ?? 0,
      failureTotalCount: (row['failure_total_count'] as int?) ?? 0,
      cooldownUntilMs: row['cooldown_until_ms'] as int?,
      lastErrorType: row['last_error_type'] as String?,
      lastErrorMessage: row['last_error_message'] as String?,
      lastFailedAt: row['last_failed_at'] as int?,
      lastSuccessAt: row['last_success_at'] as int?,
    );
  }

  bool supportsModel(String model) {
    final target = model.trim().toLowerCase();
    if (target.isEmpty) return false;
    if (models.isEmpty) return true;
    return models.any((m) => m.trim().toLowerCase() == target);
  }

  bool get isAuthFailed => (lastErrorType ?? '').trim() == 'auth_failed';

  bool get usesDefaultPriority => priority == defaultPriority;

  bool isCoolingDown([int? nowMs]) {
    final until = cooldownUntilMs;
    if (until == null || until <= 0) return false;
    return until > (nowMs ?? DateTime.now().millisecondsSinceEpoch);
  }

  String get fingerprint {
    final k = apiKey.trim();
    if (k.length <= 4) return k;
    return '?${k.substring(k.length - 4)}';
  }
}

class AIProviderKeySummary {
  final int totalCount;
  final int enabledCount;
  final int availableCount;
  final int coolingCount;
  final int errorCount;
  final int successTotal;
  final int failureTotal;
  final int? latestSuccessAt;
  final int? latestFailedAt;
  final int? updatedAt;

  const AIProviderKeySummary({
    this.totalCount = 0,
    this.enabledCount = 0,
    this.availableCount = 0,
    this.coolingCount = 0,
    this.errorCount = 0,
    this.successTotal = 0,
    this.failureTotal = 0,
    this.latestSuccessAt,
    this.latestFailedAt,
    this.updatedAt,
  });

  factory AIProviderKeySummary.fromJsonString(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const AIProviderKeySummary();
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const AIProviderKeySummary();
      int readInt(String key) {
        final raw = decoded[key];
        if (raw is int) return raw;
        if (raw is num) return raw.toInt();
        if (raw is String) return int.tryParse(raw) ?? 0;
        return 0;
      }

      int? readNullableInt(String key) {
        final raw = decoded[key];
        if (raw == null) return null;
        if (raw is int) return raw;
        if (raw is num) return raw.toInt();
        if (raw is String) return int.tryParse(raw);
        return null;
      }

      double? readNullableDouble(String key) {
        final raw = decoded[key];
        if (raw == null) return null;
        if (raw is num) return raw.toDouble();
        if (raw is String) return double.tryParse(raw);
        return null;
      }

      String? readNullableString(String key) {
        final raw = decoded[key];
        final text = raw == null ? '' : '$raw'.trim();
        return text.isEmpty ? null : text;
      }

      return AIProviderKeySummary(
        totalCount: readInt('totalCount'),
        enabledCount: readInt('enabledCount'),
        availableCount: readInt('availableCount'),
        coolingCount: readInt('coolingCount'),
        errorCount: readInt('errorCount'),
        successTotal: readInt('successTotal'),
        failureTotal: readInt('failureTotal'),
        latestSuccessAt: readNullableInt('latestSuccessAt'),
        latestFailedAt: readNullableInt('latestFailedAt'),
        updatedAt: readNullableInt('updatedAt'),
      );
    } catch (_) {
      return const AIProviderKeySummary();
    }
  }
}

class AIProvider {
  final int? id;
  final String name;
  final String type; // openai | azure_openai | claude | gemini | custom
  final String? baseUrl;
  final String? chatPath;
  final String modelsPath;
  final bool useResponseApi;
  final bool enabled;
  final bool isDefault;
  final List<String> models; // 缓存模型列表（来自 models_json）
  final Map<String, dynamic> extra; // 额外配置（如 azure apiVersion、默认模型等）
  final int? orderIndex;

  /// 列表页展示用 Key 状态摘要，缓存于 ai_providers.key_summary_json。
  final AIProviderKeySummary keySummary;

  AIProvider({
    required this.id,
    required this.name,
    required this.type,
    required this.baseUrl,
    required this.chatPath,
    required this.modelsPath,
    required this.useResponseApi,
    required this.enabled,
    required this.isDefault,
    required this.models,
    required this.extra,
    required this.orderIndex,
    this.keySummary = const AIProviderKeySummary(),
  });

  factory AIProvider.fromDbRow(Map<String, dynamic> row) {
    final modelsJson = (row['models_json'] as String?) ?? '[]';
    final extraJson = (row['extra_json'] as String?) ?? '{}';
    List<String> parsedModels;
    try {
      final v = jsonDecode(modelsJson);
      if (v is List) {
        parsedModels = v.map((e) => '$e').toList().cast<String>();
      } else {
        parsedModels = const <String>[];
      }
    } catch (_) {
      parsedModels = const <String>[];
    }
    Map<String, dynamic> parsedExtra;
    try {
      final e = jsonDecode(extraJson);
      parsedExtra = (e is Map<String, dynamic>) ? e : <String, dynamic>{};
    } catch (_) {
      parsedExtra = <String, dynamic>{};
    }
    final typeValue = (row['type'] as String?) ?? AIProviderTypes.openai;
    final normalizedModelsPath = _normalizeModelsPathOrNull(
      row['models_path'] as String?,
    );
    return AIProvider(
      id: row['id'] as int?,
      name: (row['name'] as String?) ?? '',
      type: typeValue,
      baseUrl: row['base_url'] as String?,
      chatPath: row['chat_path'] as String?,
      modelsPath: normalizedModelsPath ?? defaultModelsPathForType(typeValue),
      useResponseApi: ((row['use_response_api'] as int?) ?? 0) == 1,
      enabled: ((row['enabled'] as int?) ?? 1) == 1,
      isDefault: ((row['is_default'] as int?) ?? 0) == 1,
      models: parsedModels,
      extra: parsedExtra,
      orderIndex: row['order_index'] as int?,
      keySummary: AIProviderKeySummary.fromJsonString(
        row['key_summary_json'] as String?,
      ),
    );
  }

  String get defaultModel => (extra['default_model'] as String?) ?? '';

  AIProvider copyWith({
    int? id,
    String? name,
    String? type,
    String? baseUrl,
    String? chatPath,
    bool? useResponseApi,
    bool? enabled,
    bool? isDefault,
    List<String>? models,
    Map<String, dynamic>? extra,
    String? modelsPath,
    int? orderIndex,
    AIProviderKeySummary? keySummary,
  }) {
    return AIProvider(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      baseUrl: baseUrl ?? this.baseUrl,
      chatPath: chatPath ?? this.chatPath,
      modelsPath: modelsPath ?? this.modelsPath,
      useResponseApi: useResponseApi ?? this.useResponseApi,
      enabled: enabled ?? this.enabled,
      isDefault: isDefault ?? this.isDefault,
      models: models ?? this.models,
      extra: extra ?? this.extra,
      orderIndex: orderIndex ?? this.orderIndex,
      keySummary: keySummary ?? this.keySummary,
    );
  }

  Map<String, dynamic> toDbUpdate() {
    final normalizedModelsPath = _normalizeModelsPathForStorage(modelsPath);
    return <String, dynamic>{
      'name': name,
      'type': type,
      'base_url': baseUrl,
      'chat_path': chatPath,
      'models_path': normalizedModelsPath,
      'use_response_api': useResponseApi ? 1 : 0,
      'enabled': enabled ? 1 : 0,
      'is_default': isDefault ? 1 : 0,
      'models_json': jsonEncode(models),
      'extra_json': jsonEncode(extra),
      'order_index': orderIndex ?? 0,
    };
  }
}

/// 提供商服务：
/// - 提供商 CRUD（委托 ScreenshotDatabase）
/// - API Key 安全存储（flutter_secure_storage）
/// - 模型拉取（多厂商兼容解析）
/// - 缓存模型列表到 ai_providers.models_json
class AIProvidersService {
  AIProvidersService._();

  static final AIProvidersService instance = AIProvidersService._();

  final ScreenshotDatabase _db = ScreenshotDatabase.instance;

  // 旧版安全存储键名（用于迁移）
  String _apiKeyKey(int providerId) => 'ai_provider_key_$providerId';

  String _apiKeyFingerprint(String value) {
    final key = value.trim();
    if (key.isEmpty) return 'empty';
    final suffix = key.length <= 4 ? key : key.substring(key.length - 4);
    return 'len=${key.length},last4=$suffix';
  }

  String _providerKeyDebugList(List<AIProviderKey> keys) {
    if (keys.isEmpty) return '[]';
    return keys
        .map(
          (key) =>
              '#${key.id ?? 'null'}:${_apiKeyFingerprint(key.apiKey)} models=${key.models.length} enabled=${key.enabled}',
        )
        .join('; ');
  }

  Future<void> _logKeyFlow(String message) async {
    try {
      await FlutterLogger.nativeInfo('AI_KEY', message);
    } catch (_) {}
  }

  // ---------------- 基础 CRUD ----------------

  Future<List<AIProvider>> listProviders() async {
    final rows = await _db.listAIProviders();
    return rows.map((e) => AIProvider.fromDbRow(e)).toList();
  }

  Future<AIProvider?> getProvider(int id) async {
    final row = await _db.getAIProviderById(id);
    if (row == null) return null;
    return AIProvider.fromDbRow(row);
  }

  Future<AIProvider?> getDefaultProvider() async {
    final row = await _db.getDefaultAIProvider();
    if (row == null) return null;
    return AIProvider.fromDbRow(row);
  }

  Future<bool> setDefault(int id) => _db.setDefaultAIProvider(id);

  Future<bool> deleteProvider(int id) async {
    try {
      await SecureStorageService.instance.delete(_apiKeyKey(id));
    } catch (_) {}
    final keys = await listProviderKeys(id);
    for (final key in keys) {
      if (key.id != null) await _db.deleteAIProviderKey(key.id!);
    }
    return _db.deleteAIProvider(id);
  }

  /// 创建提供商（名称必须唯一）
  /// 返回新ID；失败返回 null
  Future<int?> createProvider({
    required String name,
    required String type,
    String? baseUrl,
    String? chatPath,
    String? modelsPath,
    bool useResponseApi = false,
    bool enabled = true,
    bool isDefault = false,
    Map<String, dynamic>? extra,
    List<String>? models,
    String? apiKey, // 将写入安全存储
    int? orderIndex,
  }) async {
    final normalizedModelsPath = _normalizeModelsPathForStorage(modelsPath);
    await _logKeyFlow(
      'service.provider.create.start name=$name type=$type models=${models?.length ?? 0} hasApiKey=${apiKey?.trim().isNotEmpty == true}',
    );
    final id = await _db.insertAIProvider(
      name: name,
      type: type,
      baseUrl: _normalizeBaseUrlOrNull(baseUrl),
      chatPath: chatPath,
      modelsPath: normalizedModelsPath,
      useResponseApi: useResponseApi,
      enabled: enabled,
      isDefault: isDefault,
      modelsJson: jsonEncode(models ?? const <String>[]),
      extraJson: jsonEncode(extra ?? const <String, dynamic>{}),
      orderIndex: orderIndex,
      apiKey: apiKey?.trim(),
    );
    await _logKeyFlow(
      'service.provider.create.inserted id=${id?.toString() ?? 'null'} name=$name',
    );
    if (id != null && apiKey != null && apiKey.trim().isNotEmpty) {
      await _logKeyFlow(
        'service.provider.create.default_key.start provider=$id key=${_apiKeyFingerprint(apiKey)} models=${models?.length ?? 0}',
      );
      await createProviderKey(
        providerId: id,
        name: 'Default key',
        apiKey: apiKey.trim(),
        models: models ?? const <String>[],
        enabled: enabled,
        priority: 100,
        orderIndex: 0,
      );
      await saveApiKey(id, apiKey.trim());
      await _logKeyFlow(
        'service.provider.create.default_key.done provider=$id',
      );
    } else if (id != null) {
      await _logKeyFlow(
        'service.provider.create.no_api_key provider=$id keepInitialModels=${models?.length ?? 0}',
      );
    }
    if (isDefault && id != null) {
      await setDefault(id);
    }
    await _logKeyFlow(
      'service.provider.create.finish id=${id?.toString() ?? 'null'}',
    );
    return id;
  }

  /// 更新提供商（按需传入字段）
  Future<bool> updateProvider({
    required int id,
    String? name,
    String? type,
    String? baseUrl,
    String? chatPath,
    String? modelsPath,
    bool? useResponseApi,
    bool? enabled,
    bool? isDefault,
    Map<String, dynamic>? extra,
    List<String>? models,
    int? orderIndex,
    String? apiKey, // 可选更新安全存储
  }) async {
    final normalizedBase = baseUrl != null
        ? _normalizeBaseUrlOrNull(baseUrl)
        : null;
    final serializedModels = models != null ? jsonEncode(models) : null;
    final serializedExtra = extra != null ? jsonEncode(extra) : null;
    final trimmedApiKey = apiKey?.trim();
    final normalizedModelsPath = modelsPath != null
        ? _normalizeModelsPathForStorage(modelsPath)
        : null;
    final bool shouldUpdateModelsPath = modelsPath != null;

    bool updated = await _db.updateAIProvider(
      id: id,
      name: name,
      type: type,
      baseUrl: normalizedBase,
      chatPath: chatPath,
      modelsPath: normalizedModelsPath,
      setModelsPath: shouldUpdateModelsPath,
      useResponseApi: useResponseApi,
      enabled: enabled,
      isDefault: isDefault,
      modelsJson: serializedModels,
      extraJson: serializedExtra,
      orderIndex: orderIndex,
      apiKey: trimmedApiKey,
    );

    if (!updated) {
      final exists = await _db.getAIProviderById(id);
      if (exists == null) {
        try {
          await FlutterLogger.nativeError(
            'AI',
            'updateProvider 未找到记录 id=$id type=${type ?? 'unknown'}',
          );
        } catch (_) {}
        return false;
      }
      bool alreadyUpToDate = true;
      if (name != null &&
          ((exists['name'] as String?) ?? '').trim() != name.trim()) {
        alreadyUpToDate = false;
      }
      if (type != null &&
          ((exists['type'] as String?) ?? '').trim() != type.trim()) {
        alreadyUpToDate = false;
      }
      if (normalizedBase != null &&
          ((exists['base_url'] as String?) ?? '').trim() !=
              normalizedBase.trim()) {
        alreadyUpToDate = false;
      }
      if (normalizedBase == null && (exists['base_url'] as String?) != null) {
        alreadyUpToDate = false;
      }
      if (chatPath != null &&
          ((exists['chat_path'] as String?) ?? '').trim() != chatPath.trim()) {
        alreadyUpToDate = false;
      }
      if (chatPath == null && (exists['chat_path'] as String?) != null) {
        alreadyUpToDate = false;
      }
      if (modelsPath != null) {
        final stored = _normalizeModelsPathForStorage(
          exists['models_path'] as String?,
        );
        if (stored != normalizedModelsPath) {
          alreadyUpToDate = false;
        }
      }
      if (useResponseApi != null) {
        final stored = ((exists['use_response_api'] as int?) ?? 0) == 1;
        if (stored != useResponseApi) alreadyUpToDate = false;
      }
      if (enabled != null) {
        final stored = ((exists['enabled'] as int?) ?? 0) == 1;
        if (stored != enabled) alreadyUpToDate = false;
      }
      if (isDefault != null) {
        final stored = ((exists['is_default'] as int?) ?? 0) == 1;
        if (stored != isDefault) alreadyUpToDate = false;
      }
      if (serializedModels != null) {
        final stored = (exists['models_json'] as String?) ?? '[]';
        if (stored != serializedModels) alreadyUpToDate = false;
      }
      if (serializedExtra != null) {
        final stored = (exists['extra_json'] as String?) ?? '{}';
        if (stored != serializedExtra) alreadyUpToDate = false;
      }
      if (orderIndex != null) {
        final stored = (exists['order_index'] as int?) ?? 0;
        if (stored != orderIndex) alreadyUpToDate = false;
      }
      if (trimmedApiKey != null) {
        final stored = (exists['api_key'] as String?)?.trim();
        if ((stored ?? '') != trimmedApiKey) {
          alreadyUpToDate = false;
        }
      }
      if (!alreadyUpToDate) {
        try {
          await FlutterLogger.nativeError(
            'AI',
            'updateProvider 异常：更新未生效 id=$id name=${name ?? exists['name']}',
          );
        } catch (_) {}
        return false;
      }
      updated = true;
      try {
        await FlutterLogger.nativeInfo(
          'AI',
          'updateProvider：DB 未变更，但值已是最新 id=$id',
        );
      } catch (_) {}
    }

    if (trimmedApiKey != null) {
      if (trimmedApiKey.isEmpty) {
        await deleteApiKey(id);
      } else {
        await saveApiKey(id, trimmedApiKey);
        final keys = await listProviderKeys(id);
        if (keys.isEmpty) {
          await createProviderKey(
            providerId: id,
            name: 'Default key',
            apiKey: trimmedApiKey,
            models: models ?? const <String>[],
          );
        } else if (keys.length == 1 && keys.first.name == 'Default key') {
          await updateProviderKey(
            id: keys.first.id!,
            apiKey: trimmedApiKey,
            models: models,
          );
        }
      }
    }
    await syncProviderModelsFromKeys(id);
    if (isDefault == true) {
      await setDefault(id);
    }
    return updated;
  }

  List<String> _normalizeModelList(Iterable<String> raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in raw) {
      final model = item.trim();
      if (model.isEmpty) continue;
      final key = model.toLowerCase();
      if (seen.add(key)) out.add(model);
    }
    return out;
  }

  Future<void> syncProviderModelsFromKeys(int providerId) async {
    await _logKeyFlow('service.keys.sync_models.start provider=$providerId');
    final keys = await listProviderKeys(providerId, includeDisabled: false);
    final models = _normalizeModelList(keys.expand((k) => k.models));
    await _db.saveAIProviderModelsJson(
      id: providerId,
      modelsJson: jsonEncode(models),
    );
    await _logKeyFlow(
      'service.keys.sync_models.done provider=$providerId enabledKeys=${keys.length} models=${models.length} keys=${_providerKeyDebugList(keys)}',
    );
  }

  Future<String?> _readLegacyApiKeyForMigration(int providerId) async {
    final dbValue = await _db.getAIProviderApiKey(providerId);
    if (dbValue != null && dbValue.trim().isNotEmpty) {
      await _logKeyFlow(
        'service.keys.legacy.read_db provider=$providerId key=${_apiKeyFingerprint(dbValue)}',
      );
      return dbValue.trim();
    }
    try {
      final old = await SecureStorageService.instance.read(
        _apiKeyKey(providerId),
      );
      if (old != null && old.trim().isNotEmpty) {
        final trimmed = old.trim();
        await _db.setAIProviderApiKey(id: providerId, apiKey: trimmed);
        try {
          await SecureStorageService.instance.delete(_apiKeyKey(providerId));
        } catch (_) {}
        await _logKeyFlow(
          'service.keys.legacy.read_secure provider=$providerId key=${_apiKeyFingerprint(trimmed)}',
        );
        return trimmed;
      }
    } catch (e) {
      await _logKeyFlow(
        'service.keys.legacy.read_secure.error provider=$providerId error=$e',
      );
    }
    await _logKeyFlow('service.keys.legacy.none provider=$providerId');
    return null;
  }

  Future<bool> _restoreLegacyKeyListIfEmpty(int providerId) async {
    await _logKeyFlow('service.keys.restore_legacy.start provider=$providerId');
    final apiKey = await _readLegacyApiKeyForMigration(providerId);
    if (apiKey == null || apiKey.isEmpty) {
      await _logKeyFlow(
        'service.keys.restore_legacy.skip provider=$providerId reason=no_legacy_key',
      );
      return false;
    }
    final row = await _db.getAIProviderById(providerId);
    final provider = row == null ? null : AIProvider.fromDbRow(row);
    final id = await _db.insertAIProviderKey(
      providerId: providerId,
      name: 'Default key',
      apiKey: apiKey,
      modelsJson: jsonEncode(
        _normalizeModelList(provider?.models ?? const <String>[]),
      ),
      enabled: true,
      priority: AIProviderKey.defaultPriority,
      orderIndex: 0,
    );
    await _logKeyFlow(
      'service.keys.restore_legacy.insert provider=$providerId keyId=${id?.toString() ?? 'null'} key=${_apiKeyFingerprint(apiKey)} models=${provider?.models.length ?? 0}',
    );
    if (id == null) return false;
    await syncProviderModelsFromKeys(providerId);
    await _db.refreshAIProviderKeySummary(providerId);
    await _logKeyFlow('service.keys.restore_legacy.done provider=$providerId');
    return true;
  }

  Future<void> _syncLegacyApiKeyFromKeys(int providerId) async {
    final keys = await listProviderKeys(providerId, includeDisabled: false);
    String? apiKey;
    for (final key in keys) {
      final value = key.apiKey.trim();
      if (value.isEmpty) continue;
      apiKey = value;
      break;
    }
    await _db.setAIProviderApiKey(id: providerId, apiKey: apiKey);
    try {
      await SecureStorageService.instance.delete(_apiKeyKey(providerId));
    } catch (_) {}
    await _logKeyFlow(
      'service.keys.sync_legacy_field provider=$providerId enabledKeys=${keys.length} selected=${apiKey == null ? 'null' : _apiKeyFingerprint(apiKey)}',
    );
  }

  Future<List<AIProviderKey>> listProviderKeys(
    int providerId, {
    bool includeDisabled = true,
  }) async {
    await _logKeyFlow(
      'service.keys.list.start provider=$providerId includeDisabled=$includeDisabled',
    );
    var rows = await _db.listAIProviderKeys(providerId);
    await _logKeyFlow(
      'service.keys.list.db_rows provider=$providerId rows=${rows.length}',
    );
    if (rows.isEmpty && await _restoreLegacyKeyListIfEmpty(providerId)) {
      rows = await _db.listAIProviderKeys(providerId);
      await _logKeyFlow(
        'service.keys.list.after_restore provider=$providerId rows=${rows.length}',
      );
    }
    final keys = rows.map((e) => AIProviderKey.fromDbRow(e)).toList();
    final visible = includeDisabled
        ? keys
        : keys.where((k) => k.enabled).toList();
    await _logKeyFlow(
      'service.keys.list.done provider=$providerId all=${keys.length} visible=${visible.length} keys=${_providerKeyDebugList(visible)}',
    );
    return visible;
  }

  Future<AIProviderKey?> getProviderKey(int keyId) async {
    final row = await _db.getAIProviderKeyById(keyId);
    return row == null ? null : AIProviderKey.fromDbRow(row);
  }

  Future<int?> createProviderKey({
    required int providerId,
    required String name,
    required String apiKey,
    List<String> models = const <String>[],
    bool enabled = true,
    int priority = 100,
    int? orderIndex,
  }) async {
    final trimmedApiKey = apiKey.trim();
    if (trimmedApiKey.isEmpty) {
      await _logKeyFlow(
        'service.keys.create.reject_empty provider=$providerId name=$name',
      );
      throw Exception('API key is required');
    }
    await _logKeyFlow(
      'service.keys.create.start provider=$providerId name=$name key=${_apiKeyFingerprint(trimmedApiKey)} models=${models.length} enabled=$enabled priority=$priority order=${orderIndex ?? 0}',
    );
    final id = await _db.insertAIProviderKey(
      providerId: providerId,
      name: name.trim().isEmpty ? 'Key' : name.trim(),
      apiKey: trimmedApiKey,
      modelsJson: jsonEncode(_normalizeModelList(models)),
      enabled: enabled,
      priority: priority,
      orderIndex: orderIndex,
    );
    await _logKeyFlow(
      'service.keys.create.insert_result provider=$providerId keyId=${id?.toString() ?? 'null'} key=${_apiKeyFingerprint(trimmedApiKey)}',
    );
    if (id == null) return null;
    await syncProviderModelsFromKeys(providerId);
    await _db.refreshAIProviderKeySummary(providerId);
    await _syncLegacyApiKeyFromKeys(providerId);
    final readback = await getProviderKey(id);
    await _logKeyFlow(
      'service.keys.create.done provider=$providerId keyId=$id readback=${readback != null} providerKeyCount=${(await listProviderKeys(providerId)).length}',
    );
    return id;
  }

  Future<bool> updateProviderKey({
    required int id,
    String? name,
    String? apiKey,
    List<String>? models,
    bool? enabled,
    int? priority,
    int? orderIndex,
    bool clearErrorState = true,
  }) async {
    final before = await getProviderKey(id);
    await _logKeyFlow(
      'service.keys.update.start keyId=$id provider=${before?.providerId ?? 'unknown'} beforeExists=${before != null} newKey=${apiKey == null ? 'unchanged' : _apiKeyFingerprint(apiKey)} models=${models?.length.toString() ?? 'unchanged'} enabled=${enabled?.toString() ?? 'unchanged'}',
    );
    final ok = await _db.updateAIProviderKey(
      id: id,
      name: name,
      apiKey: apiKey,
      modelsJson: models == null
          ? null
          : jsonEncode(_normalizeModelList(models)),
      enabled: enabled,
      priority: priority,
      orderIndex: orderIndex,
      clearErrorState: clearErrorState,
    );
    final providerId =
        before?.providerId ?? (await getProviderKey(id))?.providerId;
    if (providerId != null) {
      await syncProviderModelsFromKeys(providerId);
      await _db.refreshAIProviderKeySummary(providerId);
      await _syncLegacyApiKeyFromKeys(providerId);
    }
    await _logKeyFlow(
      'service.keys.update.done keyId=$id ok=$ok provider=${providerId ?? 'unknown'}',
    );
    return ok;
  }

  Future<bool> deleteProviderKey(int id) async {
    final before = await getProviderKey(id);
    await _logKeyFlow(
      'service.keys.delete.start keyId=$id provider=${before?.providerId ?? 'unknown'} beforeExists=${before != null}',
    );
    if (before != null) {
      await deleteApiKey(before.providerId);
    }
    final ok = await _db.deleteAIProviderKey(id);
    if (before != null) {
      await syncProviderModelsFromKeys(before.providerId);
      await _db.refreshAIProviderKeySummary(before.providerId);
      await _syncLegacyApiKeyFromKeys(before.providerId);
    }
    await _logKeyFlow(
      'service.keys.delete.done keyId=$id ok=$ok provider=${before?.providerId ?? 'unknown'}',
    );
    return ok;
  }

  Future<int> deleteAllProviderKeys(int providerId) async {
    await _logKeyFlow('service.keys.delete_all.start provider=$providerId');
    await deleteApiKey(providerId);
    final count = await _db.deleteAIProviderKeysForProvider(providerId);
    await syncProviderModelsFromKeys(providerId);
    await _db.refreshAIProviderKeySummary(providerId);
    await _logKeyFlow(
      'service.keys.delete_all.done provider=$providerId deleted=$count',
    );
    return count;
  }

  Future<List<String>> refreshModelsForKey({
    required int providerId,
    required int keyId,
    AIProvider? providerOverride,
  }) async {
    final provider = providerOverride ?? await getProvider(providerId);
    final key = await getProviderKey(keyId);
    if (provider == null) throw Exception('Provider not found');
    if (key == null) throw Exception('Provider key not found');
    try {
      final models = await fetchModels(provider: provider, apiKey: key.apiKey);
      await updateProviderKey(id: keyId, models: models, clearErrorState: true);
      await markProviderKeySuccess(keyId);
      return models;
    } catch (e) {
      await markProviderKeyFailure(
        keyId: keyId,
        errorType: 'models_fetch_failed',
        errorMessage: e.toString(),
      );
      rethrow;
    }
  }

  Future<void> markProviderKeySuccess(int keyId) async {
    await _db.markAIProviderKeySuccess(keyId);
    final key = await getProviderKey(keyId);
    if (key != null) await _db.refreshAIProviderKeySummary(key.providerId);
  }

  Future<void> markProviderKeyFailure({
    required int keyId,
    required String errorType,
    required String errorMessage,
    bool incrementFailure = true,
    int? cooldownUntilMs,
    bool resetFailureCount = false,
  }) async {
    await _db.markAIProviderKeyFailure(
      keyId: keyId,
      errorType: errorType,
      errorMessage: errorMessage,
      incrementFailure: incrementFailure,
      cooldownUntilMs: cooldownUntilMs,
      resetFailureCount: resetFailureCount,
    );
    final key = await getProviderKey(keyId);
    if (key != null) await _db.refreshAIProviderKeySummary(key.providerId);
  }

  // ---------------- API Key 存储（数据库） + 兼容迁移 ----------------

  Future<void> saveApiKey(int providerId, String apiKey) async {
    await _logKeyFlow(
      'service.legacy_api_key.save provider=$providerId key=${_apiKeyFingerprint(apiKey)}',
    );
    await _db.setAIProviderApiKey(id: providerId, apiKey: apiKey);
    // 清理旧版安全存储
    try {
      await SecureStorageService.instance.delete(_apiKeyKey(providerId));
    } catch (_) {}
  }

  Future<String?> getApiKey(int providerId) async {
    await _logKeyFlow('service.legacy_api_key.get.start provider=$providerId');
    final keys = await listProviderKeys(providerId, includeDisabled: false);
    if (keys.isNotEmpty && keys.first.apiKey.trim().isNotEmpty) {
      await _logKeyFlow(
        'service.legacy_api_key.get.from_key_list provider=$providerId key=${_apiKeyFingerprint(keys.first.apiKey)}',
      );
      return keys.first.apiKey.trim();
    }
    final v = await _db.getAIProviderApiKey(providerId);
    if (v != null && v.trim().isNotEmpty) {
      await _logKeyFlow(
        'service.legacy_api_key.get.from_db provider=$providerId key=${_apiKeyFingerprint(v)}',
      );
      return v.trim();
    }
    // 一次性迁移：若 DB 为空，尝试从安全存储读取并写回 DB
    try {
      final old = await SecureStorageService.instance.read(
        _apiKeyKey(providerId),
      );
      if (old != null && old.trim().isNotEmpty) {
        await _db.setAIProviderApiKey(id: providerId, apiKey: old.trim());
        try {
          await SecureStorageService.instance.delete(_apiKeyKey(providerId));
        } catch (_) {}
        await _logKeyFlow(
          'service.legacy_api_key.get.from_secure provider=$providerId key=${_apiKeyFingerprint(old)}',
        );
        return old.trim();
      }
    } catch (_) {}
    await _logKeyFlow('service.legacy_api_key.get.none provider=$providerId');
    return null;
  }

  Future<void> deleteApiKey(int providerId) async {
    await _logKeyFlow('service.legacy_api_key.delete provider=$providerId');
    await _db.setAIProviderApiKey(id: providerId, apiKey: null);
    try {
      await SecureStorageService.instance.delete(_apiKeyKey(providerId));
    } catch (_) {}
  }

  // ---------------- 名称唯一性校验 ----------------

  /// 校验名称是否可用（大小写不敏感）
  Future<bool> isNameAvailable(String name, {int? excludeId}) async {
    final list = await listProviders();
    final lower = name.trim().toLowerCase();
    for (final p in list) {
      if (excludeId != null && p.id == excludeId) continue;
      if (p.name.trim().toLowerCase() == lower) return false;
    }
    return true;
  }

  // ---------------- 模型拉取（多厂商适配） ----------------

  /// 刷新并持久化指定提供商的可用模型列表。
  /// 返回拉取成功的模型数组。失败抛出异常。
  Future<List<String>> refreshModels(int providerId) async {
    final provider = await getProvider(providerId);
    if (provider == null) {
      throw Exception('Provider not found');
    }
    final keys = await listProviderKeys(providerId, includeDisabled: false);
    if (keys.isNotEmpty) {
      final models = await refreshModelsForKey(
        providerId: providerId,
        keyId: keys.first.id!,
      );
      await syncProviderModelsFromKeys(providerId);
      return models;
    }
    final apiKey = await getApiKey(providerId) ?? '';
    final models = await fetchModels(provider: provider, apiKey: apiKey);
    await _db.saveAIProviderModelsJson(
      id: providerId,
      modelsJson: jsonEncode(models),
    );
    return models;
  }

  /// 根据提供商类型拉取模型列表，自动兼容主流返回结构。
  ///
  /// - OpenAI/Custom: GET {baseUrl}/v1/models
  ///   Header: Authorization: Bearer {apiKey}
  ///   解析优先 data[].id，其次数组元素的 name/id 字段。
  ///
  /// - Claude(Anthropic): GET {baseUrl}/v1/models
  ///   Header: x-api-key: {apiKey}, anthropic-version: 2023-06-01
  ///
  /// - Gemini(Google Generative Language): GET {baseUrl}/v1beta/models
  ///   Header: x-goog-api-key: {apiKey}
  ///   解析 models[].name（去掉 "models/" 前缀），可按 supportedGenerationMethods 过滤 generateContent。
  ///
  /// - Azure OpenAI: GET {baseUrl}/openai/deployments?api-version={apiVersion}
  ///   Header: api-key: {apiKey}
  ///   解析 value[].id 或 value[].name 作为部署名（聊天时通常用部署名）。
  ///
  Future<List<String>> fetchModels({
    required AIProvider provider,
    required String apiKey,
  }) async {
    final type = provider.type.trim().toLowerCase();
    late final List<String> models;
    switch (type) {
      case AIProviderTypes.openai:
      case AIProviderTypes.custom:
        final ProviderRequestIdentity identity =
            ProviderRequestIdentity.create();
        models = await _fetchOpenAIModels(
          baseUrl: _baseUrlOrDefaultOpenAI(provider.baseUrl),
          apiKey: apiKey,
          modelsPath: provider.modelsPath,
          requestHeaders: ProviderRequestHeaders.headersFromExtra(
            provider.extra,
            apiKey: apiKey,
            identity: identity,
          ),
        );
        break;
      case AIProviderTypes.claude:
        final ProviderRequestIdentity identity =
            ProviderRequestIdentity.create();
        models = await _fetchClaudeModels(
          baseUrl: _ensureBase(provider.baseUrl, 'https://api.anthropic.com'),
          apiKey: apiKey,
          modelsPath: provider.modelsPath,
          requestHeaders: ProviderRequestHeaders.headersFromExtra(
            provider.extra,
            apiKey: apiKey,
            identity: identity,
          ),
        );
        break;
      case AIProviderTypes.gemini:
        final ProviderRequestIdentity identity =
            ProviderRequestIdentity.create();
        models = await _fetchGeminiModels(
          baseUrl: _ensureBase(
            provider.baseUrl,
            'https://generativelanguage.googleapis.com',
          ),
          apiKey: apiKey,
          modelsPath: provider.modelsPath,
          requestHeaders: ProviderRequestHeaders.headersFromExtra(
            provider.extra,
            apiKey: apiKey,
            identity: identity,
          ),
        );
        break;
      case AIProviderTypes.azureOpenAI:
        final ProviderRequestIdentity identity =
            ProviderRequestIdentity.create();
        final apiVersion =
            (provider.extra['azure_api_version'] as String?) ?? '2024-02-15';
        models = await _fetchAzureOpenAIModels(
          baseUrl: _requireBase(
            provider.baseUrl,
            hint: 'https://{resource}.openai.azure.com',
          ),
          apiKey: apiKey,
          apiVersion: apiVersion,
          requestHeaders: ProviderRequestHeaders.headersFromExtra(
            provider.extra,
            apiKey: apiKey,
            identity: identity,
          ),
        );
        break;
      default:
        final ProviderRequestIdentity identity =
            ProviderRequestIdentity.create();
        // 兜底：按 OpenAI 兼容尝试
        models = await _fetchOpenAIModels(
          baseUrl: _baseUrlOrDefaultOpenAI(provider.baseUrl),
          apiKey: apiKey,
          modelsPath: provider.modelsPath,
          requestHeaders: ProviderRequestHeaders.headersFromExtra(
            provider.extra,
            apiKey: apiKey,
            identity: identity,
          ),
        );
        break;
    }
    await _cacheModelsDevPromptCaps(provider, models);
    return models;
  }

  Future<void> _cacheModelsDevPromptCaps(
    AIProvider provider,
    List<String> models,
  ) async {
    if (models.isEmpty) return;
    try {
      final int updated = await ModelsDevCatalogService.instance
          .cachePromptCapsForModels(
            models,
            providerTypeHint: provider.type,
            providerBaseUrl: provider.baseUrl,
            providerName: provider.name,
          );
      if (updated > 0) {
        await FlutterLogger.nativeInfo(
          'AI',
          'models.dev prompt caps cached provider=${provider.name} count=$updated',
        );
      }
    } catch (_) {
      // 元数据只用于增强上下文上限，不影响原模型列表刷新。
    }
  }

  // -------- 各厂商具体实现 --------

  Future<List<String>> _fetchOpenAIModels({
    required String baseUrl,
    required String apiKey,
    Map<String, String> requestHeaders = const <String, String>{},
    String? modelsPath,
  }) async {
    final uri = _resolveModelsUri(
      baseUrl: baseUrl,
      modelsPath: modelsPath,
      fallbackPath: '/v1/models',
    );
    final resp = await http.get(
      uri,
      headers: ProviderRequestHeaders.mergeHeaders(<String, String>{
        'Authorization': 'Bearer $apiKey',
      }, requestHeaders),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        'OpenAI models request failed: ${resp.statusCode} ${resp.body}',
      );
    }
    return _parseModelsFlexible(resp.body);
  }

  Future<List<String>> _fetchClaudeModels({
    required String baseUrl,
    required String apiKey,
    Map<String, String> requestHeaders = const <String, String>{},
    String? modelsPath,
  }) async {
    final uri = _resolveModelsUri(
      baseUrl: baseUrl,
      modelsPath: modelsPath,
      fallbackPath: '/v1/models',
    );
    final resp = await http.get(
      uri,
      headers: ProviderRequestHeaders.mergeHeaders(<String, String>{
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      }, requestHeaders),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        'Claude models request failed: ${resp.statusCode} ${resp.body}',
      );
    }
    return _parseModelsFlexible(resp.body);
  }

  Future<List<String>> _fetchGeminiModels({
    required String baseUrl,
    required String apiKey,
    Map<String, String> requestHeaders = const <String, String>{},
    String? modelsPath,
  }) async {
    final uri = _resolveModelsUri(
      baseUrl: baseUrl,
      modelsPath: modelsPath,
      fallbackPath: '/v1beta/models',
    );
    final resp = await http.get(
      uri,
      headers: ProviderRequestHeaders.mergeHeaders(<String, String>{
        'x-goog-api-key': apiKey,
      }, requestHeaders),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      try {
        final String bodyPreview = resp.body.length <= 4000
            ? resp.body
            : (resp.body.substring(0, 4000) + '…');
        await FlutterLogger.nativeError(
          'AI',
          '获取 Gemini 模型列表失败(${resp.statusCode}): ' + bodyPreview,
        );
        if (bodyPreview.toLowerCase().contains(
          'user location is not supported',
        )) {
          await FlutterLogger.nativeError('AI', 'Gemini 请求因地区策略被阻止');
        }
      } catch (_) {}
      throw Exception(
        'Gemini models request failed: ${resp.statusCode} ${resp.body}',
      );
    }
    try {
      final decoded = jsonDecode(resp.body);
      final List<String> out = <String>[];
      if (decoded is Map && decoded['models'] is List) {
        for (final m in (decoded['models'] as List)) {
          if (m is Map) {
            final name = (m['name']?.toString() ?? '');
            if (name.isEmpty) continue;
            // 仅保留支持文本生成的模型（尽量兼容）
            final methods =
                (m['supportedGenerationMethods'] as List?)
                    ?.map((e) => '$e')
                    .toList() ??
                const <String>[];
            final canText =
                methods.isEmpty ||
                methods.contains('generateContent') ||
                methods.contains('generateText');
            if (!canText) continue;
            out.add(
              name.startsWith('models/')
                  ? name.substring('models/'.length)
                  : name,
            );
          }
        }
      }
      return out;
    } catch (e) {
      // 回退解析
      return _parseModelsFlexible(resp.body);
    }
  }

  Future<List<String>> _fetchAzureOpenAIModels({
    required String baseUrl,
    required String apiKey,
    required String apiVersion,
    Map<String, String> requestHeaders = const <String, String>{},
  }) async {
    // 例： https://{resource}.openai.azure.com/openai/deployments?api-version=2024-02-15
    final uri = Uri.parse(
      '$baseUrl/openai/deployments?api-version=$apiVersion',
    );
    final resp = await http.get(
      uri,
      headers: ProviderRequestHeaders.mergeHeaders(<String, String>{
        'api-key': apiKey,
      }, requestHeaders),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        'Azure OpenAI deployments request failed: ${resp.statusCode} ${resp.body}',
      );
    }
    try {
      final decoded = jsonDecode(resp.body);
      final List<String> out = <String>[];
      if (decoded is Map && decoded['value'] is List) {
        for (final m in (decoded['value'] as List)) {
          if (m is Map) {
            // Azure 通常用部署名作为调用时的 model/部署名
            final id = (m['id']?.toString() ?? '');
            final name = (m['name']?.toString() ?? '');
            if (id.isNotEmpty) {
              out.add(id);
            } else if (name.isNotEmpty) {
              out.add(name);
            }
          }
        }
      }
      return out;
    } catch (e) {
      // 回退解析
      return _parseModelsFlexible(resp.body);
    }
  }

  // -------- 解析与工具 --------

  Uri _resolveModelsUri({
    required String baseUrl,
    String? modelsPath,
    required String fallbackPath,
  }) {
    final normalizedPath = _normalizeModelsPathOrNull(modelsPath);
    if (normalizedPath != null &&
        (normalizedPath.startsWith('http://') ||
            normalizedPath.startsWith('https://'))) {
      return Uri.parse(normalizedPath);
    }
    final effectivePath = normalizedPath ?? fallbackPath;
    final normalizedBase = _normalizeBaseUrlOrNull(baseUrl) ?? baseUrl;
    return Uri.parse('$normalizedBase$effectivePath');
  }

  /// 尽量兼容地解析模型列表：
  /// - { "data": [ {"id": "..."} ] }
  /// - { "models": [ {"name": "..."} ] }
  /// - [ {"id": "..."} ] 或 [ {"name": "..."} ] 或 [ "gpt-4o-mini", ... ]
  List<String> _parseModelsFlexible(String body) {
    try {
      final d = jsonDecode(body);
      final List<String> out = <String>[];

      if (d is Map) {
        if (d['data'] is List) {
          for (final e in (d['data'] as List)) {
            if (e is Map) {
              final id = (e['id']?.toString() ?? '').trim();
              final name = (e['name']?.toString() ?? '').trim();
              if (id.isNotEmpty)
                out.add(id);
              else if (name.isNotEmpty)
                out.add(name);
            } else if (e is String) {
              if (e.trim().isNotEmpty) out.add(e.trim());
            }
          }
          return out;
        }
        if (d['models'] is List) {
          for (final e in (d['models'] as List)) {
            if (e is Map) {
              final id = (e['id']?.toString() ?? '').trim();
              final name = (e['name']?.toString() ?? '').trim();
              if (name.isNotEmpty)
                out.add(name);
              else if (id.isNotEmpty)
                out.add(id);
            } else if (e is String) {
              if (e.trim().isNotEmpty) out.add(e.trim());
            }
          }
          return out;
        }
        // 其他字段名（兼容性）
        if (d.values.any((v) => v is List)) {
          for (final v in d.values) {
            if (v is List) {
              for (final e in v) {
                if (e is Map) {
                  final id = (e['id']?.toString() ?? '').trim();
                  final name = (e['name']?.toString() ?? '').trim();
                  if (id.isNotEmpty)
                    out.add(id);
                  else if (name.isNotEmpty)
                    out.add(name);
                } else if (e is String) {
                  if (e.trim().isNotEmpty) out.add(e.trim());
                }
              }
            }
          }
          if (out.isNotEmpty) return out;
        }
        // Map 非常规结构，回退为空
        return out;
      }

      if (d is List) {
        for (final e in d) {
          if (e is Map) {
            final id = (e['id']?.toString() ?? '').trim();
            final name = (e['name']?.toString() ?? '').trim();
            if (id.isNotEmpty)
              out.add(id);
            else if (name.isNotEmpty)
              out.add(name);
          } else if (e is String) {
            if (e.trim().isNotEmpty) out.add(e.trim());
          }
        }
        return out;
      }

      return const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  String? _normalizeBaseUrlOrNull(String? v) {
    if (v == null) return v;
    final s = v.trim();
    if (s.isEmpty) return '';
    // 去掉尾部 /
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  String _baseUrlOrDefaultOpenAI(String? baseUrl) {
    final b = (baseUrl == null || baseUrl.trim().isEmpty)
        ? 'https://api.openai.com'
        : baseUrl.trim();
    return _normalizeBaseUrlOrNull(b) ?? 'https://api.openai.com';
  }

  String _ensureBase(String? baseUrl, String fallback) {
    final b = (baseUrl == null || baseUrl.trim().isEmpty)
        ? fallback
        : baseUrl.trim();
    return _normalizeBaseUrlOrNull(b) ?? fallback;
  }

  String _requireBase(String? baseUrl, {String? hint}) {
    final b = (baseUrl ?? '').trim();
    if (b.isEmpty) {
      throw Exception('Base URL required${hint != null ? ' ($hint)' : ''}');
    }
    return _normalizeBaseUrlOrNull(b) ?? b;
  }
}
