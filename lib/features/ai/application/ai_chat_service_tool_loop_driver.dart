part of 'ai_chat_service.dart';

extension AIChatServiceToolLoopDriverExt on AIChatService {
  Future<AIGatewayResult> _runInitialToolLoopModelCall({
    required List<AIMessage> working,
    required List<AIMessage> requestMessages,
    required String cid,
    required int pinnedUserCreatedAtMs,
    required AIMessage pinnedUserMessage,
    required List<Map<String, dynamic>> tools,
    required Object? toolChoice,
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
    required int promptEstBefore,
    required String? promptBreakdownJson,
  }) async {
    final Stopwatch firstReq = Stopwatch()..start();
    Timer? firstHeartbeatStarter;
    Timer? firstHeartbeatTicker;
    if (tools.isNotEmpty && emitEvent != null) {
      firstHeartbeatStarter = Timer(const Duration(seconds: 12), () {
        firstHeartbeatTicker = Timer.periodic(const Duration(seconds: 10), (_) {
          final int secs = firstReq.elapsed.inSeconds;
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
      working = _replaceImageMessagesWithPlaceholder(
        working,
        keepMostRecent: true,
        cid: cid,
        stage: 'tool_loop_initial_image',
        model: modelForBudget,
      );
      working = _enforceToolLoopPromptBudget(
        working,
        pinnedUser: pinnedUserMessage,
        maxPromptTokens: _toolLoopBudgetTokensForPrompt(
          budgets: budgets,
          toolsSchemaTokens: toolsSchemaTokens,
          effectivePromptCapTokens: effectivePromptCapTokens,
        ),
        emitEvent: emitEvent,
        cid: cid,
        stage: 'tool_loop_initial_budget',
        model: modelForBudget,
      );
      AIGatewayResult result = await callModel(
        messages: working,
        toolsForCall: tools,
        toolChoiceForCall: toolChoice,
        preferStreaming: true,
        trimStage: 'tool_loop_initial_call',
        isToolLoop: tools.isNotEmpty,
        forcedPromptEstBefore: promptEstBefore,
        forcedBreakdownJson: promptBreakdownJson,
      );
      working = _replaceImageMessagesWithPlaceholder(
        working,
        keepMostRecent: false,
        cid: cid,
        stage: 'tool_loop_post_initial_image',
        model: modelForBudget,
      );
      if (tools.isNotEmpty && result.toolCalls.isEmpty) {
        final AIGatewayResult coerced = _maybeCoerceToolCallsFromText(
          result,
          tools,
        );
        if (coerced.toolCalls.isNotEmpty) {
          _emitProgress(
            emitEvent,
            _loc(
              '检测到模型以文本格式输出工具调用，已自动解析并继续执行。',
              'Detected text-form tool calls; parsed and continuing.',
            ),
          );
          result = coerced;
        }
      }
      if (_isConversationPersistenceBlockedOrStale(
        cid: cid,
        createdAtMs: pinnedUserCreatedAtMs,
      )) {
        throw StateError('Request was superseded by retry.');
      }
      _emitProgress(
        emitEvent,
        _loc(
          '模型已响应：tool_calls=${result.toolCalls.length}（${firstReq.elapsedMilliseconds}ms）',
          'Model responded: tool_calls=${result.toolCalls.length} (${firstReq.elapsedMilliseconds}ms)',
        ),
      );
      return result;
    } finally {
      firstHeartbeatStarter?.cancel();
      firstHeartbeatTicker?.cancel();
      firstReq.stop();
    }
  }
}
