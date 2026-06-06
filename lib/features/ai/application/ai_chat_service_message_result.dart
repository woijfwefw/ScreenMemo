part of 'ai_chat_service.dart';

extension AIChatServiceMessageResultExt on AIChatService {
  AIMessage _assistantMessageFromGatewayResult(
    AIGatewayResult result, {
    String? uiThinkingJson,
    Duration? responseDuration,
    List<AIMessage> rawTurnTranscript = const <AIMessage>[],
    Map<String, String> localEvidencePaths = const <String, String>{},
  }) {
    final String content = AIMessage.resolveEvidenceRefsToLocalPaths(
      _appendMissingGeneratedImageMarkers(result.content, rawTurnTranscript),
      localEvidencePaths,
    );
    unawaited(
      FlutterLogger.nativeDebug(
        'AIUsageTrace',
        [
          'SERVICE_RESULT_TO_MESSAGE',
          'model=${result.modelUsed} contentLen=${content.length} reasoningLen=${result.reasoning?.length ?? 0} toolCalls=${result.toolCalls.length}',
          'prompt=${result.usagePromptTokens ?? '-'} completion=${result.usageCompletionTokens ?? '-'} total=${result.usageTotalTokens ?? '-'} cacheHit=${result.usageCacheHitTokens ?? '-'} cacheMiss=${result.usageCacheMissTokens ?? '-'} responseMs=${responseDuration?.inMilliseconds ?? '-'}',
        ].join('\n'),
      ).catchError((_) {}),
    );
    return AIMessage(
      role: 'assistant',
      content: content,
      reasoningContent: result.reasoning,
      reasoningDuration: result.reasoningDuration,
      uiThinkingJson: (uiThinkingJson ?? '').trim().isEmpty
          ? null
          : uiThinkingJson!.trim(),
      usagePromptTokens: result.usagePromptTokens,
      usageCompletionTokens: result.usageCompletionTokens,
      usageTotalTokens: result.usageTotalTokens,
      usageCacheHitTokens: result.usageCacheHitTokens,
      usageCacheMissTokens: result.usageCacheMissTokens,
      responseDuration: responseDuration,
      webSearchCalls: result.webSearchCalls,
      citations: result.citations,
    );
  }

  String _appendMissingGeneratedImageMarkers(
    String content,
    List<AIMessage> rawTurnTranscript,
  ) {
    final List<String> markers = _extractGeneratedImageMarkersFromToolMessages(
      rawTurnTranscript,
    );
    if (markers.isEmpty) return content;
    String out = content.trimRight();
    bool changed = false;
    for (final String marker in markers) {
      if (marker.trim().isEmpty) continue;
      if (out.contains(marker)) continue;
      if (out.isNotEmpty) out = '$out\n\n';
      out = '$out$marker';
      changed = true;
    }
    return changed ? out : content;
  }

  List<String> _extractGeneratedImageMarkersFromToolMessages(
    List<AIMessage> messages,
  ) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final AIMessage message in messages) {
      if (message.role != 'tool') continue;
      final Map<String, dynamic> obj = _safeJsonObject(message.content);
      if ((obj['tool'] as String?)?.trim() != 'generate_image') continue;
      for (final String marker in _extractGeneratedImageMarkersFromToolPayload(
        obj,
      )) {
        if (marker.isNotEmpty && seen.add(marker)) out.add(marker);
      }
    }
    return out;
  }

  List<String> _extractGeneratedImageMarkersFromToolPayload(
    Map<String, dynamic> obj,
  ) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    final dynamic rawMarkers = obj['markers'];
    if (rawMarkers is List) {
      for (final dynamic value in rawMarkers) {
        final String marker = value?.toString().trim() ?? '';
        if (marker.isNotEmpty && seen.add(marker)) out.add(marker);
      }
    }
    final dynamic images = obj['images'];
    if (images is List) {
      for (final dynamic raw in images) {
        if (raw is! Map) continue;
        final Map<String, dynamic> item = Map<String, dynamic>.from(raw);
        String marker = (item['marker'] ?? '').toString().trim();
        if (marker.isEmpty) {
          final String filename = (item['filename'] ?? '').toString().trim();
          if (filename.isNotEmpty) marker = '[generated-image: $filename]';
        }
        if (marker.isNotEmpty && seen.add(marker)) out.add(marker);
      }
    }
    return out;
  }

  Future<List<String>> _generatedImageMarkersForToolCallFallback(
    String toolCallId,
  ) async {
    final String callId = toolCallId.trim();
    if (callId.isEmpty) return const <String>[];
    final List<Map<String, dynamic>> rows = await ScreenshotDatabase.instance
        .listAiGeneratedImagesByToolCallId(callId);
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final Map<String, dynamic> row in rows) {
      final String path = (row['file_path'] as String?)?.trim() ?? '';
      final String filename = _basename(path).trim();
      if (filename.isEmpty) continue;
      final String marker = '[generated-image: $filename]';
      if (seen.add(marker)) out.add(marker);
    }
    unawaited(
      FlutterLogger.nativeInfo(
        'AI_IMAGE',
        'tool.fallback_markers call=$callId rows=${rows.length} markers=${out.join("|")}',
      ),
    );
    return out;
  }

  Future<List<String>> _generatedImageMarkersForToolPayloadOrFallback(
    Map<String, dynamic> obj,
    String toolCallId,
  ) async {
    final List<String> markers = _extractGeneratedImageMarkersFromToolPayload(
      obj,
    );
    if (markers.isNotEmpty) return markers;
    return _generatedImageMarkersForToolCallFallback(toolCallId);
  }

  bool _isSuccessfulGenerateImageToolPayload(Map<String, dynamic> obj) {
    if ((obj['tool'] as String?)?.trim() != 'generate_image') return false;
    if (!_toBool(obj['ok'])) return false;
    if ((_toInt(obj['count']) ?? 0) <= 0) return false;
    return _extractGeneratedImageMarkersFromToolPayload(obj).isNotEmpty;
  }

  Future<AIMessage> sendMessageOneShot(
    String userMessage, {
    String context = 'chat',
    Duration? timeout,
    AIReasoningLevel reasoningLevel = AIReasoningLevel.auto,
  }) async {
    final List<AIEndpoint> endpoints = await _settings.getEndpointCandidates(
      context: context,
    );
    final String systemPrompt = _systemPromptForLocale(
      allowCharts: context == 'chat',
    );
    final List<AIMessage> requestMessages = _composeMessages(
      systemMessage: systemPrompt,
      history: const <AIMessage>[],
      userMessage: userMessage,
      includeHistory: false,
    );

    final Stopwatch responseSw = Stopwatch()..start();
    final AIGatewayResult result = await _gateway.complete(
      endpoints: endpoints,
      messages: requestMessages,
      responseStartMarker: AIChatService.responseStartMarker,
      timeout: timeout,
      preferStreaming: true,
      logContext: context,
      reasoningLevel: reasoningLevel,
    );
    responseSw.stop();

    return _assistantMessageFromGatewayResult(
      result,
      responseDuration: responseSw.elapsed,
    );
  }

  Future<void> clearConversation() => _settings.clearChatHistory();

  Future<List<AIMessage>> getConversation() => _settings.getChatHistory();
}
