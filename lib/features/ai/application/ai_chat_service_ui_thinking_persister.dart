part of 'ai_chat_service.dart';

class _ToolUiThinkingPersister {
  _ToolUiThinkingPersister({
    required this.cid,
    required this.displayUserMessage,
    required this.turnCreatedAtMs,
    required this.assistantCreatedAtMs,
    required this.toolsTitle,
    required this.settings,
    required this.isPersistenceBlocked,
    String? seededUiThinkingJson,
  }) : uiThinkingJson = ((seededUiThinkingJson ?? '').trim().isNotEmpty)
           ? seededUiThinkingJson!.trim()
           : null;

  final String cid;
  final String displayUserMessage;
  final int turnCreatedAtMs;
  final int assistantCreatedAtMs;
  final String toolsTitle;
  final AISettingsService settings;
  final bool Function({required String cid, required int createdAtMs})
  isPersistenceBlocked;

  String? uiThinkingJson;

  final List<Map<String, dynamic>> _payloads = <Map<String, dynamic>>[];
  Timer? _debounce;
  Future<void> _flushChain = Future<void>.value();
  bool _fallbackInserted = false;
  bool _disposed = false;
  int _reasoningLength = 0;
  bool _finished = false;
  Duration? _finishedReasoningDuration;

  bool get _blocked =>
      isPersistenceBlocked(cid: cid, createdAtMs: turnCreatedAtMs);

  Map<String, dynamic>? _tryDecodePayload(String raw) {
    final String t = raw.trim();
    if (t.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(t);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  void handle(AIStreamEvent event) {
    if (_disposed || _blocked) return;
    if (event.kind == 'reasoning') {
      final String data = event.data;
      if (data.trim().isEmpty || data.startsWith('- ')) return;
      final int start = _reasoningLength;
      _reasoningLength += data.length;
      _payloads.add(<String, dynamic>{
        'type': 'reasoning_delta',
        'reasoning_start': start,
        'reasoning_len': data.length,
      });
      uiThinkingJson = patchUiThinkingJsonWithToolUiEvent(
        uiThinkingJson,
        _payloads.last,
        assistantCreatedAtMs: assistantCreatedAtMs,
        toolsTitle: toolsTitle,
      );
      _scheduleFlush();
      return;
    }
    if (event.kind != 'ui') return;
    final Map<String, dynamic>? payload = _tryDecodePayload(event.data);
    if (payload == null) return;
    final String type = (payload['type'] ?? '').toString().trim();
    if (type != 'tool_batch_begin' &&
        type != 'tool_call_end' &&
        type != 'plan_update' &&
        type != 'todo_update' &&
        type != 'subagent_update') {
      return;
    }

    _payloads.add(payload);
    uiThinkingJson = patchUiThinkingJsonWithToolUiEvent(
      uiThinkingJson,
      payload,
      assistantCreatedAtMs: assistantCreatedAtMs,
      toolsTitle: toolsTitle,
    );
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _debounce?.cancel();
    // Keep this fairly low-frequency to avoid excessive DB churn while still
    // making the tool timeline resilient to conversation switches.
    _debounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(flushNow());
    });
  }

  void markFinished({Duration? reasoningDuration}) {
    if (_blocked) return;
    _finished = true;
    if (reasoningDuration != null && reasoningDuration.inMilliseconds > 0) {
      _finishedReasoningDuration = reasoningDuration;
    }
    uiThinkingJson = patchUiThinkingJsonFinish(
      uiThinkingJson,
      reasoningDuration: _finishedReasoningDuration,
    );
  }

  Future<void> flushNow() {
    _debounce?.cancel();
    _debounce = null;
    if (_disposed) return Future<void>.value();
    if (_blocked) {
      _payloads.clear();
      _finished = false;
      return Future<void>.value();
    }
    if (_payloads.isEmpty && !_finished) return Future<void>.value();

    final Future<void> next = _flushChain.then((_) async {
      await _flushOnce();
    });
    _flushChain = next.catchError((_) {});
    return _flushChain;
  }

  Future<void> _ensurePlaceholderExists(String uiJson) async {
    final String cidTrim = cid.trim();
    if (cidTrim.isEmpty) return;
    if (_blocked) return;
    final List<AIMessage> existing = await settings.getChatHistoryByCid(
      cidTrim,
    );
    final List<AIMessage> out = List<AIMessage>.from(existing);

    int assistantIdx = -1;
    for (int i = out.length - 1; i >= 0; i--) {
      final AIMessage m = out[i];
      if (m.role != 'assistant') continue;
      if (m.createdAt.millisecondsSinceEpoch == assistantCreatedAtMs) {
        assistantIdx = i;
        break;
      }
    }

    if (assistantIdx >= 0) {
      final AIMessage base = out[assistantIdx];
      out[assistantIdx] = AIMessage(
        role: base.role,
        content: base.content,
        createdAt: base.createdAt,
        reasoningContent: base.reasoningContent,
        reasoningDuration: base.reasoningDuration,
        uiThinkingJson: uiJson,
        usagePromptTokens: base.usagePromptTokens,
        usageCompletionTokens: base.usageCompletionTokens,
        usageTotalTokens: base.usageTotalTokens,
        usageCacheHitTokens: base.usageCacheHitTokens,
        usageCacheMissTokens: base.usageCacheMissTokens,
        responseDuration: base.responseDuration,
        webSearchCalls: base.webSearchCalls,
        citations: base.citations,
      );
      await settings.saveChatHistoryByCid(cidTrim, out);
      return;
    }

    // Fallback: insert after the matching user message if present.
    final String userTrim = displayUserMessage.trim();
    int userIdx = -1;
    for (int i = out.length - 1; i >= 0; i--) {
      final AIMessage m = out[i];
      if (m.role == 'user' && m.content.trim() == userTrim) {
        userIdx = i;
        break;
      }
    }

    final AIMessage placeholder = AIMessage(
      role: 'assistant',
      content: '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(assistantCreatedAtMs),
      uiThinkingJson: uiJson,
    );

    if (userIdx >= 0) {
      out.insert(userIdx + 1, placeholder);
    } else {
      if (userTrim.isNotEmpty) {
        out.add(AIMessage(role: 'user', content: userTrim));
      }
      out.add(placeholder);
    }
    await settings.saveChatHistoryByCid(cidTrim, out);
  }

  Future<void> _flushOnce() async {
    final String cidTrim = cid.trim();
    if (cidTrim.isEmpty || assistantCreatedAtMs <= 0) return;
    if (_blocked) {
      _payloads.clear();
      _finished = false;
      return;
    }
    final List<Map<String, dynamic>> payloads = List<Map<String, dynamic>>.from(
      _payloads,
    );

    final String? base = await ScreenshotDatabase.instance
        .getAiAssistantUiThinkingJson(cidTrim, assistantCreatedAtMs);
    String? next = (base ?? '').trim().isNotEmpty ? base : uiThinkingJson;
    for (final Map<String, dynamic> p in payloads) {
      next = patchUiThinkingJsonWithToolUiEvent(
        next,
        p,
        assistantCreatedAtMs: assistantCreatedAtMs,
        toolsTitle: toolsTitle,
      );
    }
    if (_finished) {
      next = patchUiThinkingJsonFinish(
        next,
        reasoningDuration: _finishedReasoningDuration,
      );
    }
    final String t = (next ?? '').trim();
    if (t.isEmpty) return;
    if (_blocked) {
      _payloads.clear();
      _finished = false;
      return;
    }

    int updated = await ScreenshotDatabase.instance
        .updateAiAssistantUiThinkingJson(cidTrim, assistantCreatedAtMs, t);

    if (updated <= 0 && !_fallbackInserted) {
      _fallbackInserted = true;
      try {
        await _ensurePlaceholderExists(t);
      } catch (_) {}
      updated = await ScreenshotDatabase.instance
          .updateAiAssistantUiThinkingJson(cidTrim, assistantCreatedAtMs, t);
    }

    if (updated > 0) {
      uiThinkingJson = t;
      if (payloads.isNotEmpty) {
        final int removeCount = payloads.length.clamp(0, _payloads.length);
        _payloads.removeRange(0, removeCount);
      }
      if (_finished) _finished = false;
      settings.notifyChatHistoryChanged(cidTrim);
    }
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
  }
}
