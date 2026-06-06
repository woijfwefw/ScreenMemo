part of 'ai_request_gateway.dart';

extension AIRequestGatewayPayloadsExt on AIRequestGateway {
  Map<String, dynamic> _buildGooglePayload({
    required AIEndpoint endpoint,
    required List<AIMessage> messages,
    required AIReasoningLevel reasoningLevel,
  }) {
    final List<Map<String, dynamic>> contents = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> systemParts = <Map<String, dynamic>>[];
    for (final AIMessage m in messages) {
      if (m.role == 'system') {
        final String text = m.providerContent.trim();
        if (text.isNotEmpty) {
          systemParts.add(<String, dynamic>{'text': text});
        }
        continue;
      }
      final String role = m.role == 'assistant' ? 'model' : 'user';
      final List<Map<String, dynamic>> parts = <Map<String, dynamic>>[];

      final Object? api = m.apiContent;
      if (api is List) {
        for (final dynamic raw in api) {
          if (raw is! Map) continue;
          final Map<String, dynamic> map = Map<String, dynamic>.from(raw);
          final String type = (map['type'] as String? ?? '')
              .trim()
              .toLowerCase();

          if (type == 'text' || type == 'input_text' || type == 'output_text') {
            final String txt = AIMessage.sanitizeEvidenceRefsForProvider(
              (map['text'] as String?)?.toString() ?? '',
            );
            final String t = txt.trim();
            if (t.isNotEmpty) {
              parts.add(<String, dynamic>{'text': t});
            }
            continue;
          }

          if (type == 'image_url' || type == 'input_image') {
            String url = '';
            final dynamic imageObj = map['image_url'] ?? map['imageUrl'];
            if (imageObj is String) {
              url = imageObj;
            } else if (imageObj is Map) {
              final Map<String, dynamic> imageMap = Map<String, dynamic>.from(
                imageObj,
              );
              url =
                  (imageMap['url'] as String?) ??
                  (imageMap['image_url'] as String?) ??
                  (imageMap['imageUrl'] as String?) ??
                  '';
            } else {
              url = (map['url'] as String?) ?? '';
            }
            url = url.trim();
            if (url.isEmpty) continue;

            // data:<mime>;base64,<payload>
            if (url.startsWith('data:')) {
              final int semi = url.indexOf(';');
              final int comma = url.indexOf(',');
              if (semi > 5 && comma > semi) {
                final String mime = url.substring(5, semi).trim();
                final String meta = url
                    .substring(semi + 1, comma)
                    .trim()
                    .toLowerCase();
                final String payload = url.substring(comma + 1).trim();
                if (meta.contains('base64') && payload.isNotEmpty) {
                  parts.add(<String, dynamic>{
                    'inline_data': <String, dynamic>{
                      'mime_type': mime.isEmpty
                          ? 'application/octet-stream'
                          : mime,
                      'data': payload,
                    },
                  });
                }
              }
              continue;
            }

            // Best-effort: treat as file uri (may not work for all providers).
            parts.add(<String, dynamic>{
              'file_data': <String, dynamic>{
                'mime_type': 'application/octet-stream',
                'file_uri': url,
              },
            });
            continue;
          }
        }
      }

      final String text = m.providerContent.trim();
      if (parts.isEmpty && text.isNotEmpty) {
        parts.add(<String, dynamic>{'text': text});
      }
      if (parts.isEmpty) continue;
      contents.add(<String, dynamic>{'role': role, 'parts': parts});
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'contents': contents,
    };
    if (systemParts.isNotEmpty) {
      payload['system_instruction'] = <String, dynamic>{'parts': systemParts};
    }
    _applyGoogleReasoningPayload(
      payload,
      endpoint: endpoint,
      level: reasoningLevel,
    );
    return payload;
  }

  Map<String, dynamic> _buildChatCompletionsPayload({
    required AIEndpoint endpoint,
    required List<AIMessage> messages,
    required bool stream,
    required List<Map<String, dynamic>> tools,
    required Object? toolChoice,
    required AIReasoningLevel reasoningLevel,
  }) {
    final List<Map<String, dynamic>> wireMessages = messages
        .map((AIMessage m) => m.toJson())
        .toList(growable: false);
    _fixDeepSeekToolReasoningContent(
      endpoint: endpoint,
      messages: wireMessages,
    );
    final List<Map<String, dynamic>> normalizedTools =
        _normalizeChatCompletionsTools(tools);
    final Map<String, dynamic> payload = <String, dynamic>{
      'model': endpoint.model,
      if (normalizedTools.isNotEmpty) 'tools': normalizedTools,
      if (normalizedTools.isNotEmpty && toolChoice != null)
        'tool_choice': _stableJsonValue(toolChoice),
      'messages': wireMessages,
      'stream': stream,
      if (stream) 'stream_options': <String, dynamic>{'include_usage': true},
    };
    _applyChatCompletionsReasoningPayload(
      payload,
      endpoint: endpoint,
      level: reasoningLevel,
    );
    return payload;
  }

  Future<void> _logPreparedRequestSummary({
    required String traceId,
    required AIEndpoint endpoint,
    required _PreparedRequest prepared,
    required String logContext,
    required String apiType,
    required bool stream,
  }) async {
    try {
      final dynamic decoded = jsonDecode(prepared.body);
      if (decoded is! Map) return;
      final Map<String, dynamic> payload = Map<String, dynamic>.from(decoded);
      final dynamic rawMessages = payload['messages'] ?? payload['input'];
      int messageCount = 0;
      int assistantToolMessages = 0;
      int assistantToolMessagesWithReasoning = 0;
      int toolMessages = 0;
      if (rawMessages is List) {
        messageCount = rawMessages.length;
        for (final dynamic raw in rawMessages) {
          if (raw is! Map) continue;
          final Map<String, dynamic> message = Map<String, dynamic>.from(raw);
          final String role = (message['role'] as String? ?? '').trim();
          if (role == 'tool' || message['type'] == 'function_call_output') {
            toolMessages += 1;
          }
          final dynamic toolCalls =
              message['tool_calls'] ?? message['toolCalls'];
          if (role == 'assistant' &&
              toolCalls is List &&
              toolCalls.isNotEmpty) {
            assistantToolMessages += 1;
            if (message.containsKey('reasoning_content') ||
                message.containsKey('reasoningContent')) {
              assistantToolMessagesWithReasoning += 1;
            }
          }
          if (message['type'] == 'function_call') {
            assistantToolMessages += 1;
          }
        }
      }
      final dynamic toolsRaw = payload['tools'];
      final int toolsCount = toolsRaw is List ? toolsRaw.length : 0;
      final String reasoningKeys = <String>[
        if (payload.containsKey('reasoning_effort')) 'reasoning_effort',
        if (payload.containsKey('reasoning')) 'reasoning',
        if (payload.containsKey('thinking')) 'thinking',
        if (payload.containsKey('enable_thinking')) 'enable_thinking',
        if (payload.containsKey('thinking_budget')) 'thinking_budget',
      ].join(',');
      final bool includeUsage =
          ((payload['stream_options'] is Map) &&
              ((payload['stream_options'] as Map)['include_usage'] == true)) ||
          ((payload['streamOptions'] is Map) &&
              ((payload['streamOptions'] as Map)['includeUsage'] == true));
      await FlutterLogger.nativeDebug(
        'AITrace',
        [
          'REQ_SUMMARY $traceId',
          'ctx=$logContext api=$apiType stream=${stream ? 1 : 0}',
          'provider=${endpoint.providerName ?? '-'}(${endpoint.providerId ?? '-'}) type=${endpoint.providerType ?? '-'} model=${endpoint.model}',
          'messages=$messageCount assistantToolMessages=$assistantToolMessages assistantToolReasoning=$assistantToolMessagesWithReasoning toolMessages=$toolMessages tools=$toolsCount includeUsage=${includeUsage ? 1 : 0} reasoningKeys=${reasoningKeys.isEmpty ? '-' : reasoningKeys}',
        ].join('\n'),
      );
    } catch (_) {}
  }

  void _fixDeepSeekToolReasoningContent({
    required AIEndpoint endpoint,
    required List<Map<String, dynamic>> messages,
  }) {
    if (!_isDeepSeekEndpoint(endpoint)) return;
    for (final Map<String, dynamic> message in messages) {
      final String role = (message['role'] as String? ?? '').trim();
      if (role != 'assistant') continue;
      final dynamic toolCalls = message['tool_calls'];
      if (toolCalls is! List || toolCalls.isEmpty) continue;
      final String reasoning = (message['reasoning_content'] as String? ?? '')
          .trim();
      if (reasoning.isNotEmpty) continue;
      // DeepSeek thinking mode requires this field to be passed back for an
      // assistant message that contains tool calls. Empty string keeps older
      // stored turns protocol-compatible when the original reasoning was not
      // available.
      message['reasoning_content'] = '';
    }
  }

  Map<String, dynamic> _buildResponsesPayload({
    required AIEndpoint endpoint,
    required List<AIMessage> messages,
    required bool stream,
    required List<Map<String, dynamic>> tools,
    required Object? toolChoice,
    required AIReasoningLevel reasoningLevel,
    bool codexStyle = false,
    ProviderRequestIdentity? identity,
  }) {
    final Map<String, dynamic> payload = <String, dynamic>{
      'model': endpoint.model,
      if (codexStyle) 'instructions': _extractResponsesInstructions(messages),
      if (codexStyle) 'tools': _normalizeResponsesTools(tools),
      if (!codexStyle && tools.isNotEmpty)
        'tools': _normalizeResponsesTools(tools),
      'input': _buildResponsesInputItems(
        codexStyle ? _withoutInstructionMessages(messages) : messages,
      ),
      'stream': stream,
    };
    _applyResponsesReasoningPayload(
      payload,
      endpoint: endpoint,
      level: reasoningLevel,
    );
    if (tools.isNotEmpty) {
      final Object? normalizedToolChoice = _normalizeResponsesToolChoice(
        toolChoice,
      );
      if (normalizedToolChoice != null) {
        payload['tool_choice'] = _stableJsonValue(normalizedToolChoice);
      }
    }
    if (codexStyle) {
      final ProviderRequestIdentity resolved =
          identity ?? ProviderRequestIdentity.create();
      payload['tool_choice'] = payload['tool_choice'] ?? 'auto';
      payload['parallel_tool_calls'] = tools.isNotEmpty;
      payload['reasoning'] = payload.containsKey('reasoning')
          ? payload['reasoning']
          : null;
      payload['store'] = false;
      payload['include'] = payload['include'] ?? <String>[];
      payload['prompt_cache_key'] = resolved.threadId;
      payload['client_metadata'] = <String, String>{
        'x-codex-installation-id': resolved.installationId,
      };
    }
    return payload;
  }

  String _extractResponsesInstructions(List<AIMessage> messages) {
    final List<String> instructions = <String>[];
    for (final AIMessage message in messages) {
      final String role = message.role.trim().toLowerCase();
      if (role != 'system' && role != 'developer') continue;
      final String text = message.providerContent.trim();
      if (text.isNotEmpty) instructions.add(text);
    }
    return instructions.join('\n\n');
  }

  List<AIMessage> _withoutInstructionMessages(List<AIMessage> messages) {
    return messages
        .where((AIMessage message) {
          final String role = message.role.trim().toLowerCase();
          return role != 'system' && role != 'developer';
        })
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _buildResponsesInputItems(
    List<AIMessage> messages,
  ) {
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    int syntheticCallSeq = 0;

    for (final AIMessage message in messages) {
      final String role = message.role.trim().toLowerCase();

      if (role == 'tool') {
        final String callId = (message.toolCallId ?? '').trim();
        if (callId.isNotEmpty) {
          items.add(<String, dynamic>{
            'type': 'function_call_output',
            'call_id': callId,
            'output': message.providerContent,
          });
        } else {
          final List<Map<String, dynamic>> fallbackParts =
              _buildResponsesContentParts(
                role: 'user',
                content: message.providerContent,
                apiContent: message.apiContent,
              );
          if (fallbackParts.isNotEmpty) {
            items.add(<String, dynamic>{
              'role': 'user',
              'content': fallbackParts,
            });
          }
        }
        continue;
      }

      if (role == 'assistant' &&
          message.toolCalls != null &&
          message.toolCalls!.isNotEmpty) {
        final List<Map<String, dynamic>> assistantParts =
            _buildResponsesContentParts(
              role: 'assistant',
              content: message.providerContent,
              apiContent: message.apiContent,
            );
        if (assistantParts.isNotEmpty) {
          items.add(<String, dynamic>{
            'role': 'assistant',
            'content': assistantParts,
          });
        }

        for (final Map<String, dynamic> tc in message.toolCalls!) {
          final Map<String, dynamic> map = Map<String, dynamic>.from(tc);
          final String id = ((map['id'] as String?) ?? '').trim().isNotEmpty
              ? (map['id'] as String).trim()
              : 'call_fallback_${++syntheticCallSeq}';

          String name = '';
          Object? argumentsRaw;
          final dynamic fnRaw = map['function'];
          if (fnRaw is Map) {
            final Map<String, dynamic> fn = Map<String, dynamic>.from(fnRaw);
            name = ((fn['name'] as String?) ?? '').trim();
            argumentsRaw = fn['arguments'];
          }
          name = name.isNotEmpty
              ? name
              : ((map['name'] as String?) ?? '').trim();
          argumentsRaw ??= map['arguments'];
          if (name.isEmpty) continue;

          final String arguments = _stringifyJsonLike(argumentsRaw);
          items.add(<String, dynamic>{
            'type': 'function_call',
            'call_id': id,
            'name': name,
            'arguments': arguments.isEmpty ? '{}' : arguments,
          });
        }
        continue;
      }

      final String normalizedRole =
          role == 'assistant' || role == 'system' || role == 'developer'
          ? role
          : 'user';
      final List<Map<String, dynamic>> parts = _buildResponsesContentParts(
        role: normalizedRole,
        content: message.providerContent,
        apiContent: message.apiContent,
      );
      if (parts.isEmpty) continue;
      items.add(<String, dynamic>{'role': normalizedRole, 'content': parts});
    }

    return items;
  }

  Map<String, dynamic> _buildClaudeCodeMessagesPayload({
    required AIEndpoint endpoint,
    required List<AIMessage> messages,
    required bool stream,
    required List<Map<String, dynamic>> tools,
    required AIReasoningLevel reasoningLevel,
    required ProviderRequestIdentity identity,
  }) {
    final List<Map<String, dynamic>> wireMessages = _buildClaudeMessages(
      messages,
    );
    final List<Map<String, dynamic>> system = _buildClaudeSystem(messages);
    final List<Map<String, dynamic>> normalizedTools = _normalizeClaudeTools(
      tools,
    );
    final Map<String, dynamic> payload = <String, dynamic>{
      'model': endpoint.model,
      'messages': wireMessages,
      'system': system.isEmpty ? <String, dynamic>{} : system.first,
      'tools': normalizedTools,
      'metadata': <String, dynamic>{
        'user_id': jsonEncode(<String, String>{
          'device_id': identity.installationId,
          'account_uuid': identity.uuid,
          'session_id': identity.sessionId,
        }),
      },
      'max_tokens': 8192,
      'stream': stream,
    };
    _applyClaudeThinkingPayload(payload, reasoningLevel);
    return payload;
  }

  Map<String, dynamic> _buildAnthropicMessagesPayload({
    required AIEndpoint endpoint,
    required List<AIMessage> messages,
    required bool stream,
    required List<Map<String, dynamic>> tools,
    required AIReasoningLevel reasoningLevel,
    required ProviderRequestIdentity identity,
  }) {
    final List<Map<String, dynamic>> wireMessages = _buildClaudeMessages(
      messages,
    );
    final String system = _buildClaudeSystemText(messages);
    final List<Map<String, dynamic>> normalizedTools = _normalizeClaudeTools(
      tools,
    );
    final Map<String, dynamic> payload = <String, dynamic>{
      'model': endpoint.model,
      'messages': wireMessages,
      if (system.isNotEmpty) 'system': system,
      if (normalizedTools.isNotEmpty) 'tools': normalizedTools,
      'max_tokens': 8192,
      'stream': stream,
      'metadata': <String, String>{'user_id': identity.installationId},
    };
    _applyClaudeThinkingPayload(payload, reasoningLevel);
    return payload;
  }

  String _buildClaudeSystemText(List<AIMessage> messages) {
    final List<String> out = <String>[];
    for (final AIMessage message in messages) {
      final String role = message.role.trim().toLowerCase();
      if (role != 'system' && role != 'developer') continue;
      final String text = message.providerContent.trim();
      if (text.isNotEmpty) out.add(text);
    }
    return out.join('\n\n');
  }

  List<Map<String, dynamic>> _buildClaudeSystem(List<AIMessage> messages) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final AIMessage message in messages) {
      final String role = message.role.trim().toLowerCase();
      if (role != 'system' && role != 'developer') continue;
      final String text = message.providerContent.trim();
      if (text.isEmpty) continue;
      out.add(<String, dynamic>{'type': 'text', 'text': text});
    }
    return out;
  }

  List<Map<String, dynamic>> _buildClaudeMessages(List<AIMessage> messages) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final AIMessage message in messages) {
      final String role = message.role.trim().toLowerCase();
      if (role == 'system' || role == 'developer') continue;
      if (role == 'tool') {
        final String toolUseId = (message.toolCallId ?? '').trim();
        if (toolUseId.isEmpty) continue;
        out.add(<String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'tool_result',
              'tool_use_id': toolUseId,
              'content': message.providerContent,
            },
          ],
        });
        continue;
      }

      final String normalizedRole = role == 'assistant' ? 'assistant' : 'user';
      final List<Map<String, dynamic>> parts = _buildClaudeContentParts(
        role: normalizedRole,
        content: message.providerContent,
        apiContent: message.apiContent,
      );
      if (role == 'assistant' &&
          message.toolCalls != null &&
          message.toolCalls!.isNotEmpty) {
        for (final Map<String, dynamic> call in message.toolCalls!) {
          final Map<String, dynamic>? toolUse = _claudeToolUseFromCall(call);
          if (toolUse != null) parts.add(toolUse);
        }
      }
      if (parts.isEmpty) continue;
      out.add(<String, dynamic>{'role': normalizedRole, 'content': parts});
    }
    return out;
  }

  List<Map<String, dynamic>> _buildClaudeContentParts({
    required String role,
    required String content,
    required Object? apiContent,
  }) {
    final List<Map<String, dynamic>> parts = <Map<String, dynamic>>[];
    if (apiContent is List) {
      for (final dynamic raw in apiContent) {
        if (raw is! Map) continue;
        final Map<String, dynamic> map = Map<String, dynamic>.from(raw);
        final String type = (map['type'] as String? ?? '').trim().toLowerCase();
        if (type == 'text' || type == 'input_text' || type == 'output_text') {
          final String text = AIMessage.sanitizeEvidenceRefsForProvider(
            (map['text'] as String?) ?? '',
          );
          if (text.trim().isNotEmpty) {
            parts.add(<String, dynamic>{'type': 'text', 'text': text});
          }
          continue;
        }
        if (role == 'user' && (type == 'image_url' || type == 'input_image')) {
          final Map<String, dynamic>? image = _claudeImagePartFromOpenAI(map);
          if (image != null) parts.add(image);
        }
      }
    }
    if (parts.isEmpty && content.trim().isNotEmpty) {
      parts.add(<String, dynamic>{'type': 'text', 'text': content});
    }
    return parts;
  }

  Map<String, dynamic>? _claudeImagePartFromOpenAI(Map<String, dynamic> map) {
    String url = '';
    final dynamic imageObj = map['image_url'] ?? map['imageUrl'];
    if (imageObj is String) {
      url = imageObj;
    } else if (imageObj is Map) {
      final Map<String, dynamic> imageMap = Map<String, dynamic>.from(imageObj);
      url =
          (imageMap['url'] as String?) ??
          (imageMap['image_url'] as String?) ??
          (imageMap['imageUrl'] as String?) ??
          '';
    } else {
      url = (map['url'] as String?) ?? '';
    }
    url = url.trim();
    if (!url.startsWith('data:')) return null;
    final int semi = url.indexOf(';');
    final int comma = url.indexOf(',');
    if (semi <= 5 || comma <= semi) return null;
    final String mime = url.substring(5, semi).trim();
    final String meta = url.substring(semi + 1, comma).trim().toLowerCase();
    final String data = url.substring(comma + 1).trim();
    if (!meta.contains('base64') || data.isEmpty) return null;
    return <String, dynamic>{
      'type': 'image',
      'source': <String, dynamic>{
        'type': 'base64',
        'media_type': mime.isEmpty ? 'application/octet-stream' : mime,
        'data': data,
      },
    };
  }

  Map<String, dynamic>? _claudeToolUseFromCall(Map<String, dynamic> call) {
    String id = (call['id'] as String? ?? '').trim();
    String name = (call['name'] as String? ?? '').trim();
    Object? input = call['arguments'];
    final dynamic fnRaw = call['function'];
    if (fnRaw is Map) {
      final Map<String, dynamic> fn = Map<String, dynamic>.from(fnRaw);
      if (name.isEmpty) name = (fn['name'] as String? ?? '').trim();
      input ??= fn['arguments'];
    }
    if (name.isEmpty) return null;
    if (id.isEmpty) id = _newFallbackToolCallId();
    return <String, dynamic>{
      'type': 'tool_use',
      'id': id,
      'name': name,
      'input': _parseJsonObjectOrEmpty(input),
    };
  }

  Map<String, dynamic> _parseJsonObjectOrEmpty(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(_stableJsonObject(raw));
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map) {
          return Map<String, dynamic>.from(_stableJsonObject(decoded));
        }
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _normalizeClaudeTools(
    List<Map<String, dynamic>> tools,
  ) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> raw in tools) {
      final Map<String, dynamic> map = Map<String, dynamic>.from(raw);
      if ((map['type'] as String? ?? '').trim().toLowerCase() != 'function') {
        continue;
      }
      final dynamic fnRaw = map['function'];
      String name = '';
      String description = '';
      Object? schema;
      if (fnRaw is Map) {
        final Map<String, dynamic> fn = Map<String, dynamic>.from(fnRaw);
        name = (fn['name'] as String? ?? '').trim();
        description = (fn['description'] as String? ?? '').trim();
        schema = fn['parameters'];
      } else {
        name = (map['name'] as String? ?? '').trim();
        description = (map['description'] as String? ?? '').trim();
        schema = map['parameters'] ?? map['input_schema'];
      }
      if (name.isEmpty) continue;
      out.add(<String, dynamic>{
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'input_schema': schema == null
            ? <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              }
            : _stableJsonValue(schema),
      });
    }
    out.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return out;
  }

  void _applyClaudeThinkingPayload(
    Map<String, dynamic> payload,
    AIReasoningLevel level,
  ) {
    if (level == AIReasoningLevel.auto) return;
    if (!level.isEnabled) return;
    payload['thinking'] = <String, dynamic>{
      'type': 'enabled',
      'budget_tokens': level.budgetTokens.clamp(1024, 16000).toInt(),
    };
  }

  List<Map<String, dynamic>> _buildResponsesContentParts({
    required String role,
    required String content,
    required Object? apiContent,
  }) {
    final List<Map<String, dynamic>> parts = <Map<String, dynamic>>[];
    final bool assistant = role == 'assistant';

    if (apiContent is List) {
      for (final dynamic raw in apiContent) {
        if (raw is! Map) continue;
        final Map<String, dynamic> map = Map<String, dynamic>.from(raw);
        final String type = (map['type'] as String? ?? '').trim().toLowerCase();

        if (type == 'text') {
          final String text = AIMessage.sanitizeEvidenceRefsForProvider(
            (map['text'] as String?) ?? '',
          );
          if (text.isNotEmpty) {
            parts.add(<String, dynamic>{
              'type': assistant ? 'output_text' : 'input_text',
              'text': text,
            });
          }
          continue;
        }

        if (type == 'input_text' ||
            type == 'output_text' ||
            type == 'refusal') {
          final Map<String, dynamic> sanitizedMap = Map<String, dynamic>.from(
            map,
          );
          final Object? text = sanitizedMap['text'];
          if (text is String) {
            sanitizedMap['text'] = AIMessage.sanitizeEvidenceRefsForProvider(
              text,
            );
          }
          if (assistant && (type == 'output_text' || type == 'refusal')) {
            parts.add(sanitizedMap);
          } else if (!assistant && type == 'input_text') {
            parts.add(sanitizedMap);
          }
          continue;
        }

        if (!assistant && (type == 'image_url' || type == 'input_image')) {
          String url = '';
          final dynamic imageObj = map['image_url'];
          if (imageObj is String) {
            url = imageObj;
          } else if (imageObj is Map) {
            final Map<String, dynamic> imageMap = Map<String, dynamic>.from(
              imageObj,
            );
            url =
                (imageMap['url'] as String?) ??
                (imageMap['image_url'] as String?) ??
                '';
          } else {
            url = (map['url'] as String?) ?? '';
          }
          if (url.isNotEmpty) {
            parts.add(<String, dynamic>{
              'type': 'input_image',
              'image_url': url,
            });
          }
        }
      }
    }

    if (parts.isEmpty && content.isNotEmpty) {
      parts.add(<String, dynamic>{
        'type': assistant ? 'output_text' : 'input_text',
        'text': content,
      });
    }

    return parts;
  }

  List<Map<String, dynamic>> _normalizeResponsesTools(
    List<Map<String, dynamic>> tools,
  ) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> raw in tools) {
      final Map<String, dynamic> map = Map<String, dynamic>.from(raw);
      final String type = (map['type'] as String? ?? '').trim().toLowerCase();
      if (type != 'function') {
        out.add(map);
        continue;
      }

      final dynamic fnRaw = map['function'];
      if (fnRaw is Map) {
        final Map<String, dynamic> fn = Map<String, dynamic>.from(fnRaw);
        final String name = (fn['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        out.add(<String, dynamic>{
          'type': 'function',
          'name': name,
          if ((fn['description'] as String?)?.trim().isNotEmpty == true)
            'description': (fn['description'] as String).trim(),
          if (fn['parameters'] != null)
            'parameters': _stableJsonValue(fn['parameters']),
          if (fn['strict'] != null) 'strict': fn['strict'],
        });
        continue;
      }

      final String name = (map['name'] as String? ?? '').trim();
      if (name.isEmpty) continue;
      out.add(<String, dynamic>{
        'type': 'function',
        'name': name,
        if ((map['description'] as String?)?.trim().isNotEmpty == true)
          'description': (map['description'] as String).trim(),
        if (map['parameters'] != null)
          'parameters': _stableJsonValue(map['parameters']),
        if (map['strict'] != null) 'strict': map['strict'],
      });
    }
    out.sort((a, b) => _toolSortKey(a).compareTo(_toolSortKey(b)));
    return out;
  }

  List<Map<String, dynamic>> _withAutoResponsesWebSearchTool(
    AIEndpoint endpoint,
    List<Map<String, dynamic>> tools,
  ) {
    if (!_shouldAutoInjectResponsesWebSearch(endpoint)) {
      return tools;
    }
    final bool hasWebSearch = tools.any((Map<String, dynamic> tool) {
      final String type = (tool['type'] as String? ?? '').trim().toLowerCase();
      return type == 'web_search';
    });
    if (hasWebSearch) return tools;
    return <Map<String, dynamic>>[
      ...tools,
      <String, dynamic>{'type': 'web_search'},
    ];
  }

  bool _shouldAutoInjectResponsesWebSearch(AIEndpoint endpoint) {
    if (!_modelLooksOpenAITextModel(endpoint.model)) return false;
    return true;
  }

  bool _modelLooksOpenAITextModel(String model) {
    String m = model.trim().toLowerCase();
    if (m.startsWith('openai/')) {
      m = m.substring('openai/'.length);
    }
    if (m.isEmpty) return false;
    if (m.startsWith('gpt-image') ||
        m.startsWith('dall-e') ||
        m.startsWith('tts-') ||
        m.startsWith('whisper') ||
        m.startsWith('text-embedding') ||
        m.contains('embedding') ||
        m.startsWith('sora')) {
      return false;
    }
    return m.startsWith('gpt-') ||
        m.startsWith('chatgpt-') ||
        m.startsWith('o1') ||
        m.startsWith('o3') ||
        m.startsWith('o4');
  }

  List<Map<String, dynamic>> _normalizeChatCompletionsTools(
    List<Map<String, dynamic>> tools,
  ) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> raw in tools) {
      final Map<String, dynamic> map = Map<String, dynamic>.from(raw);
      final String type = (map['type'] as String? ?? '').trim().toLowerCase();
      if (type != 'function') {
        out.add(Map<String, dynamic>.from(_stableJsonObject(map)));
        continue;
      }

      final dynamic fnRaw = map['function'];
      String name = '';
      String description = '';
      Object? parameters;
      Object? strict;
      if (fnRaw is Map) {
        final Map<String, dynamic> fn = Map<String, dynamic>.from(fnRaw);
        name = (fn['name'] as String? ?? '').trim();
        description = (fn['description'] as String? ?? '').trim();
        parameters = fn['parameters'];
        strict = fn['strict'];
      } else {
        name = (map['name'] as String? ?? '').trim();
        description = (map['description'] as String? ?? '').trim();
        parameters = map['parameters'];
        strict = map['strict'];
      }
      if (name.isEmpty) continue;
      out.add(<String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': name,
          if (description.isNotEmpty) 'description': description,
          if (parameters != null) 'parameters': _stableJsonValue(parameters),
          if (strict != null) 'strict': strict,
        },
      });
    }
    out.sort((a, b) => _toolSortKey(a).compareTo(_toolSortKey(b)));
    return out;
  }

  String _toolSortKey(Map<String, dynamic> tool) {
    final dynamic fnRaw = tool['function'];
    if (fnRaw is Map) {
      final String name = (fnRaw['name'] as String? ?? '').trim();
      if (name.isNotEmpty) return 'function:$name';
    }
    final String name = (tool['name'] as String? ?? '').trim();
    final String type = (tool['type'] as String? ?? '').trim();
    return '$type:$name:${jsonEncode(_stableJsonObject(tool))}';
  }

  Object? _stableJsonValue(Object? value) {
    if (value is Map) return _stableJsonObject(value);
    if (value is List) {
      return value.map<Object?>((e) => _stableJsonValue(e)).toList();
    }
    return value;
  }

  Map<String, dynamic> _stableJsonObject(Map<dynamic, dynamic> value) {
    final List<String> keys = value.keys.map((k) => k.toString()).toList()
      ..sort();
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final String key in keys) {
      out[key] = _stableJsonValue(value[key]);
    }
    return out;
  }

  String _hostKeyForReasoning(AIEndpoint endpoint) {
    final Uri uri = _resolveBaseUri(endpoint.baseUrl.trim());
    String host = uri.host.toLowerCase();
    if (host.startsWith('www.')) host = host.substring(4);
    return host;
  }

  bool _isDeepSeekEndpoint(AIEndpoint endpoint) {
    final String host = _hostKeyForReasoning(endpoint);
    final String providerType = (endpoint.providerType ?? '').toLowerCase();
    final String providerName = (endpoint.providerName ?? '').toLowerCase();
    final String model = endpoint.model.toLowerCase();
    return host.contains('deepseek') ||
        providerType.contains('deepseek') ||
        providerName.contains('deepseek') ||
        model.contains('deepseek');
  }

  bool _modelLooksReasoningCapable(AIEndpoint endpoint) {
    final String model = endpoint.model.toLowerCase();
    if (_isDeepSeekEndpoint(endpoint)) return true;
    return model.startsWith('o') ||
        model.contains('gpt-5') ||
        model.contains('gpt-4.1') ||
        model.contains('reason') ||
        model.contains('thinking') ||
        model.contains('deepseek-r') ||
        model.contains('qwen3') ||
        model.contains('qwq') ||
        model.contains('gemini-2.5') ||
        model.contains('gemini-3');
  }

  String _openAiChatReasoningEffort(AIReasoningLevel level) {
    // Chat Completions 的 reasoning_effort 支持 low/medium/high/xhigh；
    // off 没有等价取值，只能尽量降到 low。
    switch (level) {
      case AIReasoningLevel.low:
        return 'low';
      case AIReasoningLevel.medium:
        return 'medium';
      case AIReasoningLevel.high:
        return 'high';
      case AIReasoningLevel.xhigh:
        return 'xhigh';
      case AIReasoningLevel.off:
      case AIReasoningLevel.auto:
        return 'low';
    }
  }

  String _deepSeekReasoningEffort(AIReasoningLevel level) {
    // DeepSeek thinking mode currently documents high/max. Map the UI's low
    // and medium to high, and xhigh to max.
    switch (level) {
      case AIReasoningLevel.xhigh:
        return 'max';
      case AIReasoningLevel.low:
      case AIReasoningLevel.medium:
      case AIReasoningLevel.high:
        return 'high';
      case AIReasoningLevel.off:
      case AIReasoningLevel.auto:
        return '';
    }
  }

  String _responsesReasoningEffort(AIReasoningLevel level) {
    switch (level) {
      case AIReasoningLevel.off:
        return 'none';
      case AIReasoningLevel.low:
        return 'low';
      case AIReasoningLevel.medium:
        return 'medium';
      case AIReasoningLevel.high:
        return 'high';
      case AIReasoningLevel.xhigh:
        return 'xhigh';
      case AIReasoningLevel.auto:
        return 'auto';
    }
  }

  void _applyChatCompletionsReasoningPayload(
    Map<String, dynamic> payload, {
    required AIEndpoint endpoint,
    required AIReasoningLevel level,
  }) {
    if (level == AIReasoningLevel.auto) return;
    if (!_modelLooksReasoningCapable(endpoint)) return;

    final String host = _hostKeyForReasoning(endpoint);
    if (host.contains('openrouter.ai')) {
      payload['reasoning'] = <String, dynamic>{
        if (level == AIReasoningLevel.off)
          'effort': 'none'
        else
          'effort': level.effort,
      };
      return;
    }

    if (host.contains('dashscope.aliyuncs.com')) {
      payload['enable_thinking'] = level.isEnabled;
      if (level != AIReasoningLevel.auto) {
        payload['thinking_budget'] = level.budgetTokens;
      }
      return;
    }

    if (host.contains('ark.cn-beijing.volces.com') ||
        host.contains('api.moonshot.cn')) {
      payload['thinking'] = <String, dynamic>{
        'type': level.isEnabled ? 'enabled' : 'disabled',
      };
      return;
    }

    if (_isDeepSeekEndpoint(endpoint)) {
      payload['thinking'] = <String, dynamic>{
        'type': level.isEnabled ? 'enabled' : 'disabled',
      };
      if (level.isEnabled) {
        final String effort = _deepSeekReasoningEffort(level);
        if (effort.isNotEmpty) {
          payload['reasoning_effort'] = effort;
        }
      }
      return;
    }

    if (host.contains('api.mistral.ai')) return;

    payload['reasoning_effort'] = _openAiChatReasoningEffort(level);
  }

  void _applyResponsesReasoningPayload(
    Map<String, dynamic> payload, {
    required AIEndpoint endpoint,
    required AIReasoningLevel level,
  }) {
    if (level == AIReasoningLevel.auto) return;
    if (!_modelLooksReasoningCapable(endpoint)) return;
    payload['reasoning'] = <String, dynamic>{
      'summary': 'auto',
      'effort': _responsesReasoningEffort(level),
    };
    payload['include'] = <String>['reasoning.encrypted_content'];
  }

  void _applyGoogleReasoningPayload(
    Map<String, dynamic> payload, {
    required AIEndpoint endpoint,
    required AIReasoningLevel level,
  }) {
    if (level == AIReasoningLevel.auto) return;
    if (!_modelLooksReasoningCapable(endpoint)) return;
    final Map<String, dynamic> config = Map<String, dynamic>.from(
      (payload['generationConfig'] as Map?) ?? {},
    );
    final String model = endpoint.model.toLowerCase();
    final bool isGemini3 = model.contains('gemini-3');
    final bool isGemini25Pro =
        model.contains('gemini-2.5') && model.contains('pro');

    final Map<String, dynamic> thinking = <String, dynamic>{
      'includeThoughts': true,
    };
    switch (level) {
      case AIReasoningLevel.off:
        if (isGemini3) {
          thinking['thinkingLevel'] = 'minimal';
        } else if (!isGemini25Pro) {
          thinking['thinkingBudget'] = 0;
          thinking['includeThoughts'] = false;
        }
        break;
      case AIReasoningLevel.low:
        if (isGemini3) {
          thinking['thinkingLevel'] = 'low';
        } else {
          thinking['thinkingBudget'] = level.budgetTokens;
        }
        break;
      case AIReasoningLevel.medium:
        if (isGemini3) {
          thinking['thinkingLevel'] = 'medium';
        } else {
          thinking['thinkingBudget'] = level.budgetTokens;
        }
        break;
      case AIReasoningLevel.high:
      case AIReasoningLevel.xhigh:
        if (isGemini3) {
          thinking['thinkingLevel'] = 'high';
        } else {
          thinking['thinkingBudget'] = level.budgetTokens;
        }
        break;
      case AIReasoningLevel.auto:
        break;
    }
    config['thinkingConfig'] = thinking;
    payload['generationConfig'] = config;
  }

  Object? _normalizeResponsesToolChoice(Object? toolChoice) {
    if (toolChoice == null) return null;
    if (toolChoice is! Map) return toolChoice;

    final Map<String, dynamic> map = Map<String, dynamic>.from(toolChoice);
    final String type = (map['type'] as String? ?? '').trim().toLowerCase();
    if (type != 'function') {
      return map;
    }

    String name = (map['name'] as String? ?? '').trim();
    final dynamic fnRaw = map['function'];
    if (name.isEmpty && fnRaw is Map) {
      final Map<String, dynamic> fn = Map<String, dynamic>.from(fnRaw);
      name = (fn['name'] as String? ?? '').trim();
    }
    if (name.isEmpty) return map;
    return <String, dynamic>{'type': 'function', 'name': name};
  }

  bool _shouldUseResponsesApi({
    required AIEndpoint endpoint,
    required Uri baseUri,
    required List<Map<String, dynamic>> tools,
  }) {
    if (endpoint.useResponseApi) return true;
    if (_isResponsesPath(endpoint.chatPath)) return true;

    if (tools.isEmpty) return false;
    return false;
  }

  String _stringifyJsonLike(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }
}
