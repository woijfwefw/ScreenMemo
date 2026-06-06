part of 'ai_chat_service.dart';

extension AIChatServiceToolLoopRetriesExt on AIChatService {
  Future<({AIGatewayResult result, List<AIMessage> working})>
  _runForceRetrievalRetryIfNeeded({
    required bool shouldRun,
    required List<AIMessage> requestMessages,
    required List<AIMessage> working,
    required AIGatewayResult result,
    required List<Map<String, dynamic>> tools,
    required Object? toolChoice,
    required String cid,
    required AIMessage pinnedUserMessage,
    required AIContextBudgets budgets,
    required int toolsSchemaTokens,
    required int effectivePromptCapTokens,
    required String modelForBudget,
    required void Function(AIStreamEvent event)? emitEvent,
    required Future<AIGatewayResult> Function({
      required List<AIMessage> messages,
      required List<Map<String, dynamic>> toolsForCall,
      required Object? toolChoiceForCall,
      required bool preferStreaming,
      required String trimStage,
      required bool isToolLoop,
      int? forcedPromptEstBefore,
      String? forcedBreakdownJson,
    })
    callModel,
  }) async {
    if (!shouldRun) {
      return (result: result, working: working);
    }
    _emitProgress(
      emitEvent,
      _loc(
        '模型未调用工具；为避免草率结论，触发强制检索重试…',
        'No tool calls; forcing a retrieval retry to avoid premature answers…',
      ),
    );

    List<AIMessage> retryMessages = List<AIMessage>.from(requestMessages)
      ..add(
        AIMessage(
          role: 'user',
          content: _loc(
            '请先至少调用一次检索类工具（search_segments 或 search_screenshots_ocr）。'
                '若第一次结果为空，请更换关键词并至少再检索一次；必要时调整时间范围（start_local/end_local）或 offset/limit 分页继续检索。'
                '确认后再输出最终回答；不要在未检索前直接下结论，也不要臆造 [evidence: ...]。',
            'Call at least one retrieval tool first (search_segments or search_screenshots_ocr), '
                'if the first result is empty, try a different query and search again; '
                'adjust the time window (start_local/end_local) or page via offset/limit if needed, then answer. '
                'Do not conclude (or fabricate evidence) before searching.',
          ),
        ),
      );

    final Stopwatch retryReq = Stopwatch()..start();
    Timer? retryHeartbeatStarter;
    Timer? retryHeartbeatTicker;
    if (emitEvent != null) {
      retryHeartbeatStarter = Timer(const Duration(seconds: 12), () {
        retryHeartbeatTicker = Timer.periodic(const Duration(seconds: 10), (_) {
          final int secs = retryReq.elapsed.inSeconds;
          if (secs <= 0) return;
          _emitProgress(
            emitEvent,
            _loc(
              '等待模型响应中… 已等待 ${secs}s',
              'Waiting for model… ${secs}s elapsed',
            ),
          );
        });
      });
    }
    try {
      retryMessages = _replaceImageMessagesWithPlaceholder(
        retryMessages,
        keepMostRecent: true,
        cid: cid,
        stage: 'tool_loop_force_retry_image',
        model: modelForBudget,
      );
      retryMessages = _enforceToolLoopPromptBudget(
        retryMessages,
        pinnedUser: pinnedUserMessage,
        maxPromptTokens: _toolLoopBudgetTokensForPrompt(
          budgets: budgets,
          toolsSchemaTokens: toolsSchemaTokens,
          effectivePromptCapTokens: effectivePromptCapTokens,
        ),
        emitEvent: emitEvent,
        cid: cid,
        stage: 'tool_loop_force_retry_budget',
        model: modelForBudget,
      );
      result = await callModel(
        messages: retryMessages,
        toolsForCall: tools,
        toolChoiceForCall: toolChoice,
        preferStreaming: true,
        trimStage: 'tool_loop_force_retry_call',
        isToolLoop: true,
      );
    } finally {
      retryHeartbeatStarter?.cancel();
      retryHeartbeatTicker?.cancel();
      retryReq.stop();
    }
    retryMessages = _replaceImageMessagesWithPlaceholder(
      retryMessages,
      keepMostRecent: false,
      cid: cid,
      stage: 'tool_loop_force_retry_post_image',
      model: modelForBudget,
    );
    if (result.toolCalls.isEmpty) {
      result = _maybeCoerceToolCallsFromText(result, tools);
    }
    _emitProgress(
      emitEvent,
      _loc(
        '重试后模型已响应：tool_calls=${result.toolCalls.length}（${retryReq.elapsedMilliseconds}ms）',
        'Retry responded: tool_calls=${result.toolCalls.length} (${retryReq.elapsedMilliseconds}ms)',
      ),
    );
    return (result: result, working: List<AIMessage>.from(retryMessages));
  }

  Future<
    ({
      AIGatewayResult result,
      List<AIMessage> working,
      bool forcedEmptySearchRetry,
    })
  >
  _runContinueSearchRetryIfNeeded({
    required bool shouldRun,
    required String lastRetrievalTool,
    required List<AIMessage> working,
    required AIGatewayResult result,
    required List<Map<String, dynamic>> tools,
    required Object? toolChoice,
    required String cid,
    required AIMessage pinnedUserMessage,
    required AIContextBudgets budgets,
    required int toolsSchemaTokens,
    required int effectivePromptCapTokens,
    required String modelForBudget,
    required void Function(AIStreamEvent event)? emitEvent,
    required Future<AIGatewayResult> Function({
      required List<AIMessage> messages,
      required List<Map<String, dynamic>> toolsForCall,
      required Object? toolChoiceForCall,
      required bool preferStreaming,
      required String trimStage,
      required bool isToolLoop,
      int? forcedPromptEstBefore,
      String? forcedBreakdownJson,
    })
    callModel,
    required bool forcedEmptySearchRetry,
  }) async {
    if (!shouldRun) {
      return (
        result: result,
        working: working,
        forcedEmptySearchRetry: forcedEmptySearchRetry,
      );
    }
    forcedEmptySearchRetry = true;
    final String suffix = lastRetrievalTool.isEmpty
        ? ''
        : '（$lastRetrievalTool count=0）';
    _emitProgress(
      emitEvent,
      _loc(
        '检索结果为空且模型准备直接下结论$suffix；触发继续检索重试…',
        'Empty search results and the model is about to conclude$suffix; forcing a continued-search retry…',
      ),
    );

    List<AIMessage> retryMessages = List<AIMessage>.from(working)
      ..add(
        AIMessage(
          role: 'user',
          content: _loc(
            '注意：上一次检索结果为空（count=0），不能据此直接断言“没有/未找到”。\n'
                '在输出最终答复前，请按以下流程继续：\n'
                '1) 至少再调用 2 次检索类工具（search_segments / search_screenshots_ocr / search_ai_image_meta），并更换关键词（拆词/同义词/英文）。\n'
                '2) 若本次查询范围较大，请调整 start_local/end_local 覆盖不同时间段，或使用 offset/limit 分页获取更多结果；若工具返回 paging.prev/paging.next，也可使用它们继续。\n'
                '3) 若多次检索仍为空，先给出“已覆盖范围/未覆盖范围/证据缺口”，仅在硬阻塞时允许询问 1 条关键线索。\n'
                '确认后再给最终答复；不要臆造证据或 [evidence: ...]。',
            'Note: the last retrieval returned count=0, so you must not conclude “not found” yet.\n'
                'Before answering, do ALL of the following:\n'
                '1) Make at least 2 more retrieval calls (search_segments / search_screenshots_ocr / search_ai_image_meta) with alternative keywords (split words / synonyms / English).\n'
                '2) If the overall range is large, adjust start_local/end_local to cover different windows or page via offset/limit; if the tool returns paging.prev/paging.next you may use them as well.\n'
                '3) If still empty, report covered scope / uncovered scope / evidence gaps first; ask at most ONE key follow-up only on hard blockers.\n'
                'Do not fabricate evidence or [evidence: ...].',
          ),
        ),
      );

    final Stopwatch retryReq = Stopwatch()..start();
    Timer? retryHeartbeatStarter;
    Timer? retryHeartbeatTicker;
    if (emitEvent != null) {
      retryHeartbeatStarter = Timer(const Duration(seconds: 12), () {
        retryHeartbeatTicker = Timer.periodic(const Duration(seconds: 10), (_) {
          final int secs = retryReq.elapsed.inSeconds;
          if (secs <= 0) return;
          _emitProgress(
            emitEvent,
            _loc(
              '等待模型响应中… 已等待 ${secs}s',
              'Waiting for model… ${secs}s elapsed',
            ),
          );
        });
      });
    }
    try {
      retryMessages = _replaceImageMessagesWithPlaceholder(
        retryMessages,
        keepMostRecent: true,
        cid: cid,
        stage: 'tool_loop_empty_retry_image',
        model: modelForBudget,
      );
      retryMessages = _enforceToolLoopPromptBudget(
        retryMessages,
        pinnedUser: pinnedUserMessage,
        maxPromptTokens: _toolLoopBudgetTokensForPrompt(
          budgets: budgets,
          toolsSchemaTokens: toolsSchemaTokens,
          effectivePromptCapTokens: effectivePromptCapTokens,
        ),
        emitEvent: emitEvent,
        cid: cid,
        stage: 'tool_loop_empty_retry_budget',
        model: modelForBudget,
      );
      result = await callModel(
        messages: retryMessages,
        toolsForCall: tools,
        toolChoiceForCall: toolChoice,
        preferStreaming: true,
        trimStage: 'tool_loop_empty_retry_call',
        isToolLoop: true,
      );
    } finally {
      retryHeartbeatStarter?.cancel();
      retryHeartbeatTicker?.cancel();
      retryReq.stop();
    }
    retryMessages = _replaceImageMessagesWithPlaceholder(
      retryMessages,
      keepMostRecent: false,
      cid: cid,
      stage: 'tool_loop_empty_retry_post_image',
      model: modelForBudget,
    );
    if (result.toolCalls.isEmpty) {
      result = _maybeCoerceToolCallsFromText(result, tools);
    }
    _emitProgress(
      emitEvent,
      _loc(
        '继续检索重试后模型已响应：tool_calls=${result.toolCalls.length}（${retryReq.elapsedMilliseconds}ms）',
        'Continued-search retry responded: tool_calls=${result.toolCalls.length} (${retryReq.elapsedMilliseconds}ms)',
      ),
    );
    return (
      result: result,
      working: List<AIMessage>.from(retryMessages),
      forcedEmptySearchRetry: forcedEmptySearchRetry,
    );
  }

  Future<
    ({
      AIGatewayResult result,
      List<AIMessage> working,
      bool forcedEmptySearchRetry,
    })
  >
  _runAutoPagingRetryIfNeeded({
    required bool shouldRun,
    required List<AIMessage> working,
    required AIGatewayResult result,
    required List<Map<String, dynamic>> tools,
    required Object? toolChoice,
    required String cid,
    required AIMessage pinnedUserMessage,
    required AIContextBudgets budgets,
    required int toolsSchemaTokens,
    required int effectivePromptCapTokens,
    required String modelForBudget,
    required void Function(AIStreamEvent event)? emitEvent,
    required Future<AIGatewayResult> Function({
      required List<AIMessage> messages,
      required List<Map<String, dynamic>> toolsForCall,
      required Object? toolChoiceForCall,
      required bool preferStreaming,
      required String trimStage,
      required bool isToolLoop,
      int? forcedPromptEstBefore,
      String? forcedBreakdownJson,
    })
    callModel,
    required bool forcedEmptySearchRetry,
  }) async {
    if (!shouldRun) {
      return (
        result: result,
        working: working,
        forcedEmptySearchRetry: forcedEmptySearchRetry,
      );
    }
    forcedEmptySearchRetry = true;
    _emitProgress(
      emitEvent,
      _loc(
        '检测到可继续翻页但模型准备停机追问；触发自动翻页覆盖重试…',
        'Paging is available but model is stopping for clarification; forcing an auto-paging retry…',
      ),
    );

    List<AIMessage> retryMessages = List<AIMessage>.from(working)
      ..add(
        AIMessage(
          role: 'user',
          content: _loc(
            '当前检索结果仍可继续扩展（存在 paging/clamped 提示）。\n'
                '请不要先向用户提问；先继续自动翻页覆盖范围并补充证据。\n'
                '输出时请明确：已覆盖范围、未覆盖范围、下一步计划。\n'
                '仅当出现硬阻塞（权限/数据源缺失/输入冲突）时，才允许询问 1 个关键问题。',
            'Current retrieval can still be expanded (paging/clamped hints present).\n'
                'Do not ask the user first; continue auto-paging to expand coverage and gather evidence.\n'
                'In your answer, state covered scope, uncovered scope, and next steps.\n'
                'Only ask ONE key question on hard blockers (permission/data source/input conflict).',
          ),
        ),
      );

    final Stopwatch retryReq = Stopwatch()..start();
    Timer? retryHeartbeatStarter;
    Timer? retryHeartbeatTicker;
    if (emitEvent != null) {
      retryHeartbeatStarter = Timer(const Duration(seconds: 12), () {
        retryHeartbeatTicker = Timer.periodic(const Duration(seconds: 10), (_) {
          final int secs = retryReq.elapsed.inSeconds;
          if (secs <= 0) return;
          _emitProgress(
            emitEvent,
            _loc(
              '等待模型响应中… 已等待 ${secs}s',
              'Waiting for model… ${secs}s elapsed',
            ),
          );
        });
      });
    }
    try {
      retryMessages = _replaceImageMessagesWithPlaceholder(
        retryMessages,
        keepMostRecent: true,
        cid: cid,
        stage: 'tool_loop_auto_paging_retry_image',
        model: modelForBudget,
      );
      retryMessages = _enforceToolLoopPromptBudget(
        retryMessages,
        pinnedUser: pinnedUserMessage,
        maxPromptTokens: _toolLoopBudgetTokensForPrompt(
          budgets: budgets,
          toolsSchemaTokens: toolsSchemaTokens,
          effectivePromptCapTokens: effectivePromptCapTokens,
        ),
        emitEvent: emitEvent,
        cid: cid,
        stage: 'tool_loop_auto_paging_retry_budget',
        model: modelForBudget,
      );
      result = await callModel(
        messages: retryMessages,
        toolsForCall: tools,
        toolChoiceForCall: toolChoice,
        preferStreaming: true,
        trimStage: 'tool_loop_auto_paging_retry_call',
        isToolLoop: true,
      );
    } finally {
      retryHeartbeatStarter?.cancel();
      retryHeartbeatTicker?.cancel();
      retryReq.stop();
    }
    retryMessages = _replaceImageMessagesWithPlaceholder(
      retryMessages,
      keepMostRecent: false,
      cid: cid,
      stage: 'tool_loop_auto_paging_retry_post_image',
      model: modelForBudget,
    );
    if (result.toolCalls.isEmpty) {
      result = _maybeCoerceToolCallsFromText(result, tools);
    }
    _emitProgress(
      emitEvent,
      _loc(
        '自动翻页覆盖重试后模型已响应：tool_calls=${result.toolCalls.length}（${retryReq.elapsedMilliseconds}ms）',
        'Auto-paging retry responded: tool_calls=${result.toolCalls.length} (${retryReq.elapsedMilliseconds}ms)',
      ),
    );
    return (
      result: result,
      working: List<AIMessage>.from(retryMessages),
      forcedEmptySearchRetry: forcedEmptySearchRetry,
    );
  }
}
