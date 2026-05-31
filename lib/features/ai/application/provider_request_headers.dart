import 'dart:convert';
import 'dart:math';

/// AI 提供商请求头配置的统一读写与合并工具。
///
/// 配置复用 ai_providers.extra_json，避免为小型扩展新增数据库列。
class ProviderRequestHeaders {
  ProviderRequestHeaders._();

  static const String extraKey = 'request_headers';
  static const String bodyStyleExtraKey = 'request_body_style';
  static const String apiKeyPlaceholder = '{api_key}';
  static const String uuidPlaceholder = '{uuid}';
  static const String sessionIdPlaceholder = '{session_id}';
  static const String threadIdPlaceholder = '{thread_id}';
  static const String installationIdPlaceholder = '{installation_id}';
  static const String windowIdPlaceholder = '{window_id}';
  static const String timestampMsPlaceholder = '{timestamp_ms}';
  static const String codexUserAgent =
      'codex_cli_rs/0.133.0 (Windows 10.0.0; x86_64) unknown';

  static final RegExp _headerNamePattern = RegExp(
    r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$",
  );

  static const Map<String, String> _sensitiveNames = <String, String>{
    'authorization': 'authorization',
    'proxy-authorization': 'proxy-authorization',
    'x-api-key': 'x-api-key',
    'api-key': 'api-key',
    'x-goog-api-key': 'x-goog-api-key',
    'openai-api-key': 'openai-api-key',
    'anthropic-api-key': 'anthropic-api-key',
    'cookie': 'cookie',
    'set-cookie': 'set-cookie',
  };

  static List<ProviderHeaderEntry> entriesFromExtra(
    Map<String, dynamic>? extra,
  ) {
    if (extra == null) return const <ProviderHeaderEntry>[];
    return entriesFromRaw(extra[extraKey]);
  }

  static List<ProviderHeaderEntry> entriesFromRaw(Object? raw) {
    if (raw == null) return const <ProviderHeaderEntry>[];
    final List<ProviderHeaderEntry> out = <ProviderHeaderEntry>[];

    void add(Object? nameRaw, Object? valueRaw) {
      final String name = (nameRaw ?? '').toString().trim();
      final String value = (valueRaw ?? '').toString().trim();
      if (name.isEmpty && value.isEmpty) return;
      out.add(ProviderHeaderEntry(name: name, value: value));
    }

    if (raw is String) {
      final String text = raw.trim();
      if (text.isEmpty) return const <ProviderHeaderEntry>[];
      try {
        return entriesFromRaw(jsonDecode(text));
      } catch (_) {
        return const <ProviderHeaderEntry>[];
      }
    }
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map) {
          add(
            item['name'] ?? item['key'] ?? item['header'],
            item['value'] ?? item['val'],
          );
        }
      }
      return normalizeEntries(out);
    }
    if (raw is Map) {
      raw.forEach((Object? key, Object? value) => add(key, value));
      return normalizeEntries(out);
    }
    return const <ProviderHeaderEntry>[];
  }

  static Map<String, dynamic> writeEntriesToExtra(
    Map<String, dynamic> extra,
    Iterable<ProviderHeaderEntry> entries,
  ) {
    final List<Map<String, String>> serialized = normalizeEntries(entries)
        .map((ProviderHeaderEntry entry) => entry.toJson())
        .toList(growable: false);
    final Map<String, dynamic> next = <String, dynamic>{...extra};
    if (serialized.isEmpty) {
      next.remove(extraKey);
    } else {
      next[extraKey] = serialized;
    }
    return next;
  }

  static String bodyStyleFromExtra(
    Map<String, dynamic>? extra, {
    String? providerType,
  }) {
    final String normalizedType = (providerType ?? '').trim().toLowerCase();
    if (extra == null) {
      return normalizedType == 'claude'
          ? ProviderRequestBodyStyles.anthropicMessages
          : ProviderRequestBodyStyles.defaultStyle;
    }
    if (!extra.containsKey(bodyStyleExtraKey) && normalizedType == 'claude') {
      return ProviderRequestBodyStyles.anthropicMessages;
    }
    return ProviderRequestBodyStyles.normalize(extra[bodyStyleExtraKey]);
  }

  static Map<String, dynamic> writeBodyStyleToExtra(
    Map<String, dynamic> extra,
    String style,
  ) {
    final String normalized = ProviderRequestBodyStyles.normalize(style);
    final Map<String, dynamic> next = <String, dynamic>{...extra};
    if (normalized == ProviderRequestBodyStyles.defaultStyle) {
      next.remove(bodyStyleExtraKey);
    } else {
      next[bodyStyleExtraKey] = normalized;
    }
    return next;
  }

  static List<ProviderHeaderEntry> normalizeEntries(
    Iterable<ProviderHeaderEntry> entries,
  ) {
    final Map<String, ProviderHeaderEntry> byLower =
        <String, ProviderHeaderEntry>{};
    for (final ProviderHeaderEntry entry in entries) {
      final String name = entry.name.trim();
      final String value = entry.value.trim();
      if (name.isEmpty && value.isEmpty) continue;
      if (name.isEmpty || value.isEmpty) {
        byLower[name.toLowerCase()] = ProviderHeaderEntry(
          name: name,
          value: value,
        );
        continue;
      }
      byLower[name.toLowerCase()] = ProviderHeaderEntry(
        name: name,
        value: value,
      );
    }
    return byLower.values.toList(growable: false);
  }

  static List<ProviderHeaderEntry> invalidEntries(
    Iterable<ProviderHeaderEntry> entries,
  ) {
    return normalizeEntries(entries)
        .where((ProviderHeaderEntry entry) {
          final String name = entry.name.trim();
          final String value = entry.value.trim();
          if (name.isEmpty && value.isEmpty) return false;
          if (name.isEmpty || value.isEmpty) return true;
          return !isValidHeaderName(name) || _hasInvalidHeaderValue(value);
        })
        .toList(growable: false);
  }

  static bool isValidHeaderName(String name) {
    final String value = name.trim();
    if (value.isEmpty) return false;
    return _headerNamePattern.hasMatch(value);
  }

  static ProviderRequestIdentity createIdentity() =>
      ProviderRequestIdentity.create();

  static Map<String, String> headersFromExtra(
    Map<String, dynamic>? extra, {
    required String apiKey,
    ProviderRequestIdentity? identity,
  }) {
    return resolveEntries(
      entriesFromExtra(extra),
      apiKey: apiKey,
      identity: identity,
    );
  }

  static Map<String, String> resolveEntries(
    Iterable<ProviderHeaderEntry> entries, {
    required String apiKey,
    ProviderRequestIdentity? identity,
  }) {
    final Map<String, String> out = <String, String>{};
    final ProviderRequestIdentity resolvedIdentity =
        identity ?? ProviderRequestIdentity.create();
    for (final ProviderHeaderEntry entry in normalizeEntries(entries)) {
      final String name = entry.name.trim();
      if (!isValidHeaderName(name)) continue;
      final String value = _resolvePlaceholders(
        entry.value,
        apiKey: apiKey,
        identity: resolvedIdentity,
      ).trim();
      if (value.isEmpty || _hasInvalidHeaderValue(value)) continue;
      _setCaseInsensitive(out, name, value);
    }
    return out;
  }

  static Map<String, String> mergeHeaders(
    Map<String, String> base,
    Map<String, String> overrides, {
    bool allowContentTypeOverride = true,
  }) {
    final Map<String, String> out = <String, String>{};
    base.forEach((String key, String value) {
      if (!isValidHeaderName(key) || value.trim().isEmpty) return;
      if (_hasInvalidHeaderValue(value)) return;
      _setCaseInsensitive(out, key.trim(), value.trim());
    });
    overrides.forEach((String key, String value) {
      final String normalizedKey = key.trim();
      if (!isValidHeaderName(normalizedKey) || value.trim().isEmpty) return;
      if (_hasInvalidHeaderValue(value)) return;
      if (!allowContentTypeOverride &&
          normalizedKey.toLowerCase() == 'content-type') {
        return;
      }
      _setCaseInsensitive(out, normalizedKey, value.trim());
    });
    return out;
  }

  static Map<String, String> redactForLog(Map<String, String> headers) {
    final Map<String, String> out = <String, String>{};
    headers.forEach((String key, String value) {
      out[key] = maskedHeaderValue(key, value);
    });
    return out;
  }

  static String maskedHeaderValue(String name, String value) {
    final String key = name.trim().toLowerCase();
    if (_sensitiveNames.containsKey(key) || key.contains('token')) {
      if (key == 'authorization') {
        final String trimmed = value.trim();
        return trimmed.toLowerCase().startsWith('bearer ')
            ? 'Bearer ***'
            : '***';
      }
      return '***';
    }
    return value;
  }

  static List<ProviderHeaderTemplate> templatesForProviderType(String type) {
    final String normalized = type.trim().toLowerCase();
    final List<ProviderHeaderTemplate> out = <ProviderHeaderTemplate>[
      ProviderHeaderTemplates.openAI,
      ProviderHeaderTemplates.anthropic,
      ProviderHeaderTemplates.codexCompatible,
      ProviderHeaderTemplates.claudeCodeRouter,
    ];
    switch (normalized) {
      case 'claude':
        return <ProviderHeaderTemplate>[
          ProviderHeaderTemplates.anthropic,
          ProviderHeaderTemplates.claudeCodeRouter,
          ProviderHeaderTemplates.openAI,
          ProviderHeaderTemplates.codexCompatible,
        ];
      case 'custom':
        return <ProviderHeaderTemplate>[
          ProviderHeaderTemplates.openAI,
          ProviderHeaderTemplates.claudeCodeRouter,
          ProviderHeaderTemplates.codexCompatible,
          ProviderHeaderTemplates.anthropic,
        ];
      default:
        return out;
    }
  }

  static String _resolvePlaceholders(
    String value, {
    required String apiKey,
    required ProviderRequestIdentity identity,
  }) {
    return value
        .replaceAll(apiKeyPlaceholder, apiKey.trim())
        .replaceAll(uuidPlaceholder, identity.uuid)
        .replaceAll(sessionIdPlaceholder, identity.sessionId)
        .replaceAll(threadIdPlaceholder, identity.threadId)
        .replaceAll(installationIdPlaceholder, identity.installationId)
        .replaceAll(windowIdPlaceholder, identity.windowId)
        .replaceAll(timestampMsPlaceholder, identity.timestampMs);
  }

  static bool _hasInvalidHeaderValue(String value) {
    return value.codeUnits.any((int code) => code < 0x20 && code != 0x09);
  }

  static void _setCaseInsensitive(
    Map<String, String> target,
    String name,
    String value,
  ) {
    final String lower = name.toLowerCase();
    String? existing;
    for (final String key in target.keys) {
      if (key.toLowerCase() == lower) {
        existing = key;
        break;
      }
    }
    if (existing != null) target.remove(existing);
    target[name] = value;
  }

  static String newUuid() => _uuidV4();

  static String _uuidV4() {
    final Random random = _secureRandom();
    int nextByte() => random.nextInt(256);
    final List<int> bytes = List<int>.generate(16, (_) => nextByte());
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hexByte(int value) => value.toRadixString(16).padLeft(2, '0');
    final String hex = bytes.map(hexByte).join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static Random _secureRandom() {
    try {
      return Random.secure();
    } catch (_) {
      return Random();
    }
  }
}

class ProviderHeaderEntry {
  const ProviderHeaderEntry({required this.name, required this.value});

  final String name;
  final String value;

  Map<String, String> toJson() => <String, String>{
    'name': name.trim(),
    'value': value.trim(),
  };
}

class ProviderHeaderTemplate {
  const ProviderHeaderTemplate({
    required this.id,
    required this.label,
    required this.entries,
    this.bodyStyle = ProviderRequestBodyStyles.defaultStyle,
  });

  final String id;
  final String label;
  final List<ProviderHeaderEntry> entries;
  final String bodyStyle;
}

class ProviderRequestBodyStyles {
  ProviderRequestBodyStyles._();

  static const String defaultStyle = 'default';
  static const String codexResponses = 'codex_responses';
  static const String anthropicMessages = 'anthropic_messages';
  static const String claudeCodeMessages = 'claude_code_messages';

  static const List<String> values = <String>[
    defaultStyle,
    codexResponses,
    anthropicMessages,
    claudeCodeMessages,
  ];

  static String normalize(Object? raw) {
    final String value = (raw ?? '').toString().trim().toLowerCase();
    switch (value) {
      case codexResponses:
      case 'codex':
      case 'codex_compatible':
      case 'responses_codex':
        return codexResponses;
      case anthropicMessages:
      case 'anthropic':
      case 'claude_messages':
      case 'messages':
        return anthropicMessages;
      case claudeCodeMessages:
      case 'claude_code':
      case 'claudecode':
      case 'claude_code_router':
        return claudeCodeMessages;
      default:
        return defaultStyle;
    }
  }
}

class ProviderRequestIdentity {
  const ProviderRequestIdentity({
    required this.uuid,
    required this.sessionId,
    required this.threadId,
    required this.installationId,
    required this.windowId,
    required this.timestampMs,
  });

  factory ProviderRequestIdentity.create() {
    final String uuid = ProviderRequestHeaders.newUuid();
    final String threadId = ProviderRequestHeaders.newUuid();
    return ProviderRequestIdentity(
      uuid: uuid,
      sessionId: uuid,
      threadId: threadId,
      installationId: ProviderRequestHeaders.newUuid(),
      windowId: '$threadId:0',
      timestampMs: DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  final String uuid;
  final String sessionId;
  final String threadId;
  final String installationId;
  final String windowId;
  final String timestampMs;
}

class ProviderHeaderTemplates {
  ProviderHeaderTemplates._();

  static const ProviderHeaderTemplate openAI = ProviderHeaderTemplate(
    id: 'openai',
    label: 'OpenAI',
    entries: <ProviderHeaderEntry>[
      ProviderHeaderEntry(
        name: 'Authorization',
        value: 'Bearer ${ProviderRequestHeaders.apiKeyPlaceholder}',
      ),
    ],
  );

  static const ProviderHeaderTemplate anthropic = ProviderHeaderTemplate(
    id: 'anthropic',
    label: 'Anthropic / Claude API',
    bodyStyle: ProviderRequestBodyStyles.anthropicMessages,
    entries: <ProviderHeaderEntry>[
      ProviderHeaderEntry(
        name: 'x-api-key',
        value: ProviderRequestHeaders.apiKeyPlaceholder,
      ),
      ProviderHeaderEntry(name: 'anthropic-version', value: '2023-06-01'),
    ],
  );

  static const ProviderHeaderTemplate codexCompatible = ProviderHeaderTemplate(
    id: 'codex_compatible',
    label: 'Codex compatible',
    bodyStyle: ProviderRequestBodyStyles.codexResponses,
    entries: <ProviderHeaderEntry>[
      ProviderHeaderEntry(
        name: 'Authorization',
        value: 'Bearer ${ProviderRequestHeaders.apiKeyPlaceholder}',
      ),
      ProviderHeaderEntry(name: 'originator', value: 'codex_cli_rs'),
      ProviderHeaderEntry(
        name: 'User-Agent',
        value: ProviderRequestHeaders.codexUserAgent,
      ),
      ProviderHeaderEntry(
        name: 'session-id',
        value: ProviderRequestHeaders.sessionIdPlaceholder,
      ),
      ProviderHeaderEntry(
        name: 'thread-id',
        value: ProviderRequestHeaders.threadIdPlaceholder,
      ),
      ProviderHeaderEntry(
        name: 'x-client-request-id',
        value: ProviderRequestHeaders.threadIdPlaceholder,
      ),
      ProviderHeaderEntry(
        name: 'x-codex-window-id',
        value: ProviderRequestHeaders.windowIdPlaceholder,
      ),
    ],
  );

  static const ProviderHeaderTemplate claudeCodeRouter = ProviderHeaderTemplate(
    id: 'claude_code_router',
    label: 'Claude Code API key',
    bodyStyle: ProviderRequestBodyStyles.claudeCodeMessages,
    entries: <ProviderHeaderEntry>[
      ProviderHeaderEntry(
        name: 'Authorization',
        value: 'Bearer ${ProviderRequestHeaders.apiKeyPlaceholder}',
      ),
      ProviderHeaderEntry(
        name: 'x-api-key',
        value: ProviderRequestHeaders.apiKeyPlaceholder,
      ),
      ProviderHeaderEntry(name: 'Accept', value: 'application/json'),
      ProviderHeaderEntry(name: 'anthropic-version', value: '2023-06-01'),
      ProviderHeaderEntry(
        name: 'anthropic-beta',
        value: 'prompt-caching-scope-2026-01-05,claude-code-20250219',
      ),
      ProviderHeaderEntry(
        name: 'anthropic-dangerous-direct-browser-access',
        value: 'true',
      ),
      ProviderHeaderEntry(name: 'x-app', value: 'cli'),
      ProviderHeaderEntry(
        name: 'User-Agent',
        value: 'claude-cli/2.1.121 (external, sdk-cli)',
      ),
      ProviderHeaderEntry(
        name: 'X-Claude-Code-Session-Id',
        value: ProviderRequestHeaders.sessionIdPlaceholder,
      ),
      ProviderHeaderEntry(name: 'x-stainless-arch', value: 'x64'),
      ProviderHeaderEntry(name: 'x-stainless-lang', value: 'js'),
      ProviderHeaderEntry(name: 'x-stainless-os', value: 'Windows'),
      ProviderHeaderEntry(name: 'x-stainless-package-version', value: '0.81.0'),
      ProviderHeaderEntry(name: 'x-stainless-retry-count', value: '0'),
      ProviderHeaderEntry(name: 'x-stainless-runtime', value: 'node'),
      ProviderHeaderEntry(
        name: 'x-stainless-runtime-version',
        value: 'v24.3.0',
      ),
      ProviderHeaderEntry(name: 'x-stainless-timeout', value: '600'),
    ],
  );
}
