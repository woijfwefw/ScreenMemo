part of 'ai_chat_service.dart';

typedef _SubagentModelCaller =
    Future<AIGatewayResult> Function({
      required List<AIMessage> messages,
      required List<Map<String, dynamic>> toolsForCall,
      required Object? toolChoiceForCall,
      required bool preferStreaming,
      required String trimStage,
      required bool isToolLoop,
      void Function(AIStreamEvent event)? streamEventSink,
    });

class _SubagentTask {
  const _SubagentTask({
    required this.id,
    required this.name,
    required this.role,
    required this.task,
    required this.instructions,
  });

  final String id;
  final String name;
  final String role;
  final String task;
  final String instructions;
}

class _SubagentResult {
  const _SubagentResult({
    required this.task,
    required this.ok,
    required this.content,
    required this.model,
    required this.durationMs,
    required this.conversationCid,
    required this.contextTokensEstimate,
    required this.contextCapTokens,
    this.reasoning,
    this.error,
  });

  final _SubagentTask task;
  final bool ok;
  final String content;
  final String model;
  final int durationMs;
  final String conversationCid;
  final int contextTokensEstimate;
  final int contextCapTokens;
  final String? reasoning;
  final String? error;
}

class _SubagentAgentRun {
  const _SubagentAgentRun({
    required this.result,
    required this.transcript,
    required this.totalToolCalls,
  });

  final AIGatewayResult result;
  // UI transcript shown by the normal chat renderer for this child agent.
  final List<AIMessage> transcript;
  final int totalToolCalls;
}

class _SubagentModelTurn {
  const _SubagentModelTurn({
    required this.result,
    required this.assistantCreatedAt,
  });

  final AIGatewayResult result;
  final DateTime assistantCreatedAt;
}

extension AIChatServiceSubagentsExt on AIChatService {
  static const int _subagentMaxThreads = 3;
  static const int _subagentMaxTasks = 6;
  static const int _subagentMaxToolIters = 10;

  static Map<String, dynamic> buildDelegateSubagentsToolSchema() {
    return <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'delegate_subagents',
        'description':
            'Explicitly delegate independent work to parallel child agents. Use only when the user asks for subagents/parallel agents, or when a complex task benefits from separate exploration streams. Child agents may use normal tools, but cannot create more subagents and cannot update the main TODO list.',
        'parameters': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'reason': <String, dynamic>{
              'type': 'string',
              'description':
                  'Why delegation is needed. Keep it concise and tied to the user request.',
            },
            'tasks': <String, dynamic>{
              'type': 'array',
              'minItems': 1,
              'maxItems': _subagentMaxTasks,
              'description':
                  'Independent child-agent tasks. They may run in parallel.',
              'items': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'id': <String, dynamic>{
                    'type': 'string',
                    'description':
                        'Stable short id for this child task, such as explorer_1.',
                  },
                  'name': <String, dynamic>{
                    'type': 'string',
                    'description': 'Short display name for the child agent.',
                  },
                  'role': <String, dynamic>{
                    'type': 'string',
                    'enum': <String>['explorer', 'worker', 'reviewer'],
                    'description':
                        'Child-agent style. explorer gathers context, worker solves a focused slice, reviewer checks risks.',
                  },
                  'task': <String, dynamic>{
                    'type': 'string',
                    'description':
                        'Specific child-agent assignment. Keep it focused and independently answerable.',
                  },
                  'instructions': <String, dynamic>{
                    'type': 'string',
                    'description':
                        'Optional extra constraints for this child task.',
                  },
                },
                'required': <String>['task'],
              },
            },
          },
          'required': <String>['tasks'],
        },
      },
    };
  }

  bool _isDelegateSubagentsTool(AIToolCall call) =>
      call.name.trim() == 'delegate_subagents';

  Future<List<AIMessage>> _executeDelegateSubagentsToolCall(
    AIToolCall call, {
    required List<AIMessage> rootMessages,
    required String userTask,
    required String parentConversationCid,
    required int parentAssistantCreatedAtMs,
    required String modelForContextCap,
    required int contextCapTokens,
    required void Function(AIStreamEvent event)? emitEvent,
    required _SubagentModelCaller callModel,
  }) async {
    final Map<String, dynamic> args = _safeJsonObject(call.argumentsJson);
    final List<_SubagentTask> tasks = _parseSubagentTasks(args);
    if (tasks.isEmpty) {
      return <AIMessage>[
        AIMessage(
          role: 'tool',
          toolCallId: call.id,
          content: jsonEncode(<String, dynamic>{
            'tool': 'delegate_subagents',
            'ok': false,
            'error': 'invalid_subagent_tasks',
            'message': 'No valid subagent tasks were provided.',
          }),
        ),
      ];
    }

    _emitSubagentUpdate(
      emitEvent,
      agents: tasks
          .map(
            (_SubagentTask task) => <String, dynamic>{
              'id': task.id,
              'name': task.name,
              'role': task.role,
              'status': 'queued',
              'summary': task.task,
              'model': modelForContextCap,
            },
          )
          .toList(growable: false),
    );

    final List<_SubagentResult> results = await _runSubagentTasks(
      tasks,
      rootMessages: rootMessages,
      userTask: userTask,
      parentConversationCid: parentConversationCid,
      parentAssistantCreatedAtMs: parentAssistantCreatedAtMs,
      parentToolCallId: call.id,
      modelForContextCap: modelForContextCap,
      contextCapTokens: contextCapTokens,
      emitEvent: emitEvent,
      callModel: callModel,
    );

    final Map<String, dynamic> payload = <String, dynamic>{
      'tool': 'delegate_subagents',
      'ok': results.every((_SubagentResult r) => r.ok),
      'reason': (args['reason'] as String?)?.trim() ?? '',
      'max_threads': _subagentMaxThreads,
      'results': results
          .map(
            (_SubagentResult result) => <String, dynamic>{
              'id': result.task.id,
              'name': result.task.name,
              'role': result.task.role,
              'task': result.task.task,
              'ok': result.ok,
              'content': result.content,
              'model': result.model,
              'duration_ms': result.durationMs,
              'conversation_cid': result.conversationCid,
              'context_tokens_estimate': result.contextTokensEstimate,
              'context_cap_tokens': result.contextCapTokens,
              'context_percent': _contextPercent(
                result.contextTokensEstimate,
                result.contextCapTokens,
              ),
              if ((result.reasoning ?? '').trim().isNotEmpty)
                'reasoning': result.reasoning,
              if ((result.error ?? '').trim().isNotEmpty) 'error': result.error,
            },
          )
          .toList(growable: false),
      'summary': _summarizeSubagentResults(results),
    };

    return <AIMessage>[
      AIMessage(
        role: 'tool',
        toolCallId: call.id,
        content: jsonEncode(payload),
      ),
    ];
  }

  List<_SubagentTask> _parseSubagentTasks(Map<String, dynamic> args) {
    final dynamic rawTasks = args['tasks'] ?? args['agents'];
    if (rawTasks is! List) return const <_SubagentTask>[];

    final List<_SubagentTask> tasks = <_SubagentTask>[];
    final Set<String> ids = <String>{};
    for (final dynamic raw in rawTasks.take(_subagentMaxTasks)) {
      if (raw is! Map) continue;
      final Map<String, dynamic> map = Map<String, dynamic>.from(raw);
      final String task = ((map['task'] ?? map['prompt'])?.toString() ?? '')
          .trim();
      if (task.isEmpty) continue;
      final String fallbackId = 'subagent_${tasks.length + 1}';
      String id = ((map['id'] ?? map['name'])?.toString() ?? '').trim();
      id = _normalizeSubagentId(id.isEmpty ? fallbackId : id);
      if (id.isEmpty) id = fallbackId;
      if (ids.contains(id)) {
        var suffix = 2;
        var next = '${id}_$suffix';
        while (ids.contains(next)) {
          suffix += 1;
          next = '${id}_$suffix';
        }
        id = next;
      }
      ids.add(id);

      final String roleRaw = ((map['role'] ?? map['type'])?.toString() ?? '')
          .trim()
          .toLowerCase();
      final String role = switch (roleRaw) {
        'worker' => 'worker',
        'reviewer' => 'reviewer',
        _ => 'explorer',
      };
      final String nameRaw = (map['name'] ?? '').toString().trim();
      final String name = nameRaw.isEmpty
          ? _defaultSubagentName(role, id)
          : nameRaw;
      final String instructions =
          (map['instructions'] ?? map['developer_instructions'] ?? '')
              .toString()
              .trim();
      tasks.add(
        _SubagentTask(
          id: id,
          name: name,
          role: role,
          task: task,
          instructions: instructions,
        ),
      );
    }
    return tasks;
  }

  Future<List<_SubagentResult>> _runSubagentTasks(
    List<_SubagentTask> tasks, {
    required List<AIMessage> rootMessages,
    required String userTask,
    required String parentConversationCid,
    required int parentAssistantCreatedAtMs,
    required String parentToolCallId,
    required String modelForContextCap,
    required int contextCapTokens,
    required void Function(AIStreamEvent event)? emitEvent,
    required _SubagentModelCaller callModel,
  }) async {
    final List<_SubagentResult?> results = List<_SubagentResult?>.filled(
      tasks.length,
      null,
    );
    final int? providerId = await _resolveSubagentProviderId(
      parentConversationCid,
    );

    Future<void> runTaskAt(int index, {String peerResultsContext = ''}) async {
      final _SubagentTask task = tasks[index];
      final List<AIMessage> subagentMessages = _buildSubagentMessages(
        task,
        rootMessages: rootMessages,
        userTask: userTask,
        peerResultsContext: peerResultsContext,
      );
      final List<AIMessage> displayMessages = _buildSubagentDisplayMessages(
        task,
      );
      final int contextTokensEstimate =
          PromptBudget.approxTokensForMessagesJson(subagentMessages);
      final String childCid = await _settings.createSubagentConversation(
        parentCid: parentConversationCid,
        parentAssistantCreatedAt: parentAssistantCreatedAtMs,
        parentToolCallId: parentToolCallId,
        subagentId: task.id,
        title: task.name,
        role: task.role,
        providerId: providerId,
        model: modelForContextCap,
        contextTokens: contextTokensEstimate,
        contextCapTokens: contextCapTokens,
      );
      await _settings.saveChatHistoryByCid(childCid, displayMessages);
      _emitSubagentUpdate(
        emitEvent,
        agents: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': task.id,
            'name': task.name,
            'role': task.role,
            'status': 'working',
            'summary': task.task,
            'model': modelForContextCap,
            'conversation_cid': childCid,
            'context_tokens_estimate': contextTokensEstimate,
            'context_cap_tokens': contextCapTokens,
            'context_percent': _contextPercent(
              contextTokensEstimate,
              contextCapTokens,
            ),
          },
        ],
      );

      final Stopwatch sw = Stopwatch()..start();
      try {
        final _SubagentAgentRun run = await _runSubagentAgentLoop(
          task: task,
          initialMessages: subagentMessages,
          initialDisplayMessages: displayMessages,
          childCid: childCid,
          modelForBudget: modelForContextCap,
          callModel: callModel,
          onLiveContent: (String content) {
            final String summary = _clipLine(content, maxLen: 220);
            if (summary.trim().isEmpty) return;
            _emitSubagentUpdate(
              emitEvent,
              agents: <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': task.id,
                  'name': task.name,
                  'role': task.role,
                  'status': 'working',
                  'summary': summary,
                  'model': modelForContextCap,
                  'conversation_cid': childCid,
                  'context_tokens_estimate': contextTokensEstimate,
                  'context_cap_tokens': contextCapTokens,
                  'context_percent': _contextPercent(
                    contextTokensEstimate,
                    contextCapTokens,
                  ),
                },
              ],
            );
          },
        );
        sw.stop();
        final AIGatewayResult result = run.result;
        results[index] = _SubagentResult(
          task: task,
          ok: true,
          content: result.content,
          model: result.modelUsed.trim().isEmpty
              ? modelForContextCap
              : result.modelUsed,
          durationMs: sw.elapsedMilliseconds,
          conversationCid: childCid,
          contextTokensEstimate: contextTokensEstimate,
          contextCapTokens: contextCapTokens,
          reasoning: result.reasoning,
        );
        await _settings.saveChatHistoryByCid(childCid, run.transcript);
        _emitSubagentUpdate(
          emitEvent,
          agents: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': task.id,
              'name': task.name,
              'role': task.role,
              'status': 'completed',
              'summary': _clipLine(
                run.totalToolCalls > 0
                    ? '${result.content} (${run.totalToolCalls} tool call(s))'
                    : result.content,
                maxLen: 220,
              ),
              'model': result.modelUsed.trim().isEmpty
                  ? modelForContextCap
                  : result.modelUsed,
              'duration_ms': sw.elapsedMilliseconds,
              'conversation_cid': childCid,
              'context_tokens_estimate': contextTokensEstimate,
              'context_cap_tokens': contextCapTokens,
              'context_percent': _contextPercent(
                contextTokensEstimate,
                contextCapTokens,
              ),
            },
          ],
        );
      } catch (error) {
        sw.stop();
        final String message = error.toString();
        results[index] = _SubagentResult(
          task: task,
          ok: false,
          content: '',
          model: modelForContextCap,
          durationMs: sw.elapsedMilliseconds,
          conversationCid: childCid,
          contextTokensEstimate: contextTokensEstimate,
          contextCapTokens: contextCapTokens,
          error: message,
        );
        await _settings.saveChatHistoryByCid(childCid, <AIMessage>[
          ...displayMessages,
          AIMessage(role: 'error', content: message),
        ]);
        _emitSubagentUpdate(
          emitEvent,
          agents: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': task.id,
              'name': task.name,
              'role': task.role,
              'status': 'failed',
              'summary': _clipLine(message, maxLen: 220),
              'model': modelForContextCap,
              'duration_ms': sw.elapsedMilliseconds,
              'conversation_cid': childCid,
              'context_tokens_estimate': contextTokensEstimate,
              'context_cap_tokens': contextCapTokens,
              'context_percent': _contextPercent(
                contextTokensEstimate,
                contextCapTokens,
              ),
            },
          ],
        );
      }
    }

    Future<void> runBatch(
      List<int> indices, {
      String peerResultsContext = '',
    }) async {
      if (indices.isEmpty) return;
      var nextIndex = 0;
      Future<void> worker() async {
        while (true) {
          final int slot = nextIndex;
          nextIndex += 1;
          if (slot >= indices.length) return;
          await runTaskAt(
            indices[slot],
            peerResultsContext: peerResultsContext,
          );
        }
      }

      final int workers = indices.length < _subagentMaxThreads
          ? indices.length
          : _subagentMaxThreads;
      await Future.wait(List<Future<void>>.generate(workers, (_) => worker()));
    }

    final List<int> primaryIndices = <int>[];
    final List<int> reviewIndices = <int>[];
    for (int i = 0; i < tasks.length; i += 1) {
      if (_isReviewerSubagentTask(tasks[i])) {
        reviewIndices.add(i);
      } else {
        primaryIndices.add(i);
      }
    }

    if (primaryIndices.isEmpty) {
      await runBatch(reviewIndices);
      return results.whereType<_SubagentResult>().toList(growable: false);
    }

    await runBatch(primaryIndices);
    if (reviewIndices.isNotEmpty) {
      final String peerResultsContext = _subagentPeerResultsContext(
        results.whereType<_SubagentResult>().toList(growable: false),
      );
      await runBatch(reviewIndices, peerResultsContext: peerResultsContext);
    }
    return results.whereType<_SubagentResult>().toList(growable: false);
  }

  Future<_SubagentAgentRun> _runSubagentAgentLoop({
    required _SubagentTask task,
    required List<AIMessage> initialMessages,
    required List<AIMessage> initialDisplayMessages,
    required String childCid,
    required String modelForBudget,
    required _SubagentModelCaller callModel,
    void Function(String content)? onLiveContent,
  }) async {
    final List<Map<String, dynamic>> tools =
        AIChatService.defaultSubagentTools();
    final Object? toolChoice = tools.isEmpty ? null : 'auto';
    final List<AIMessage> working = List<AIMessage>.from(initialMessages);
    final List<AIMessage> display = List<AIMessage>.from(
      initialDisplayMessages,
    );
    int totalToolCalls = 0;
    final Map<String, String> liveEvidencePaths = <String, String>{};
    Timer? displaySaveDebounce;
    Future<void> displaySaveChain = Future<void>.value();
    final DateTime liveAssistantCreatedAt = DateTime.now();
    String liveContent = '';
    String liveReasoning = '';
    int liveReasoningLength = 0;
    String? liveUiThinkingJson;

    Future<void> persistDisplaySnapshot(List<AIMessage> snapshot) async {
      await _settings.saveChatHistoryByCid(childCid, snapshot);
      _settings.notifyChatHistoryChanged(childCid);
    }

    Future<void> enqueueDisplaySave() {
      final List<AIMessage> snapshot = List<AIMessage>.from(display);
      final Future<void> next = displaySaveChain.then(
        (_) => persistDisplaySnapshot(snapshot),
      );
      displaySaveChain = next.catchError((_) {});
      return next;
    }

    void scheduleDisplaySave({
      Duration delay = const Duration(milliseconds: 350),
    }) {
      displaySaveDebounce?.cancel();
      displaySaveDebounce = Timer(delay, () {
        displaySaveDebounce = null;
        unawaited(enqueueDisplaySave());
      });
    }

    Future<void> flushDisplaySave() async {
      displaySaveDebounce?.cancel();
      displaySaveDebounce = null;
      await enqueueDisplaySave();
    }

    AIMessage buildDisplayAssistant({
      required DateTime createdAt,
      required String content,
      String? reasoning,
      Duration? reasoningDuration,
      String? uiThinkingJson,
      AIGatewayResult? result,
    }) {
      final String reasoningText = (reasoning ?? '').trim();
      final String uiJsonText = (uiThinkingJson ?? '').trim();
      final String resolvedContent = AIMessage.resolveEvidenceRefsToLocalPaths(
        content,
        liveEvidencePaths,
      );
      return AIMessage(
        role: 'assistant',
        content: resolvedContent,
        createdAt: createdAt,
        reasoningContent: reasoningText.isEmpty ? null : reasoning,
        reasoningDuration: reasoningDuration,
        uiThinkingJson: uiJsonText.isEmpty ? null : uiThinkingJson,
        usagePromptTokens: result?.usagePromptTokens,
        usageCompletionTokens: result?.usageCompletionTokens,
        usageTotalTokens: result?.usageTotalTokens,
        usageCacheHitTokens: result?.usageCacheHitTokens,
        usageCacheMissTokens: result?.usageCacheMissTokens,
        webSearchCalls: result?.webSearchCalls ?? const <AIWebSearchCall>[],
        citations: result?.citations ?? const <AIUrlCitation>[],
      );
    }

    void upsertDisplayAssistant({
      required DateTime createdAt,
      required String content,
      String? reasoning,
      Duration? reasoningDuration,
      String? uiThinkingJson,
      AIGatewayResult? result,
    }) {
      final int createdAtMs = createdAt.millisecondsSinceEpoch;
      final AIMessage message = buildDisplayAssistant(
        createdAt: createdAt,
        content: content,
        reasoning: reasoning,
        reasoningDuration: reasoningDuration,
        uiThinkingJson: uiThinkingJson,
        result: result,
      );
      final int idx = display.indexWhere(
        (AIMessage m) =>
            m.role == 'assistant' &&
            m.createdAt.millisecondsSinceEpoch == createdAtMs,
      );
      if (idx >= 0) {
        display[idx] = message;
      } else {
        final int lastAssistantIndex = display.lastIndexWhere(
          (AIMessage m) => m.role == 'assistant',
        );
        if (lastAssistantIndex >= 0) {
          display[lastAssistantIndex] = message;
        } else {
          display.add(message);
        }
      }
    }

    Future<_SubagentModelTurn> runModelForDisplay({
      required List<AIMessage> messages,
      required String trimStage,
      required bool isToolLoop,
      Object? toolChoiceForCall,
      List<Map<String, dynamic>> toolsForCall = const <Map<String, dynamic>>[],
    }) async {
      void updateLiveDisplay({AIGatewayResult? result}) {
        upsertDisplayAssistant(
          createdAt: liveAssistantCreatedAt,
          content: liveContent,
          reasoning: liveReasoning,
          reasoningDuration: result?.reasoningDuration,
          uiThinkingJson: liveUiThinkingJson,
          result: result,
        );
      }

      final AIGatewayResult result = await callModel(
        messages: messages,
        toolsForCall: toolsForCall,
        toolChoiceForCall: toolChoiceForCall,
        preferStreaming: true,
        trimStage: trimStage,
        isToolLoop: isToolLoop,
        streamEventSink: (AIStreamEvent event) {
          if (event.kind == 'content') {
            if (event.data.isEmpty) return;
            liveContent += event.data;
            updateLiveDisplay();
            onLiveContent?.call(liveContent);
            // 子代理详情页是只读实时窗口；首段内容必须尽快落库，避免
            // 打开子代理时只能看到结束后的最终结果。
            unawaited(flushDisplaySave());
            return;
          }
          if (event.kind != 'reasoning') return;
          final String delta = event.data;
          if (delta.trim().isEmpty) return;
          final int start = liveReasoningLength;
          liveReasoningLength += delta.length;
          liveReasoning += delta;
          liveUiThinkingJson = patchUiThinkingJsonWithToolUiEvent(
            liveUiThinkingJson,
            <String, dynamic>{
              'type': 'reasoning_delta',
              'reasoning_start': start,
              'reasoning_len': delta.length,
            },
            assistantCreatedAtMs: liveAssistantCreatedAt.millisecondsSinceEpoch,
            toolsTitle: _loc('工具调用', 'Tools'),
          );
          updateLiveDisplay();
          scheduleDisplaySave();
        },
      );

      if (result.content.isNotEmpty) {
        liveContent = result.content;
      }
      if ((result.reasoning ?? '').trim().isNotEmpty) {
        liveReasoning = result.reasoning!;
        liveReasoningLength = liveReasoning.length;
      }
      updateLiveDisplay(result: result);
      await flushDisplaySave();
      return _SubagentModelTurn(
        result: result,
        assistantCreatedAt: liveAssistantCreatedAt,
      );
    }

    upsertDisplayAssistant(
      createdAt: liveAssistantCreatedAt,
      content: liveContent,
    );
    await flushDisplaySave();

    _SubagentModelTurn turn = await runModelForDisplay(
      messages: working,
      toolsForCall: tools,
      toolChoiceForCall: toolChoice,
      trimStage: 'subagent_${task.id}_initial',
      isToolLoop: tools.isNotEmpty,
    );
    AIGatewayResult result = turn.result;

    int iters = 0;
    while (result.toolCalls.isNotEmpty && iters < _subagentMaxToolIters) {
      iters += 1;
      final AIMessage assistantToolCallMessage = AIMessage(
        role: 'assistant',
        content: result.content,
        createdAt: turn.assistantCreatedAt,
        reasoningContent: result.reasoning,
        reasoningDuration: result.reasoningDuration,
        toolCalls: result.toolCalls
            .map((AIToolCall call) => call.toOpenAIToolCallJson())
            .toList(growable: false),
        webSearchCalls: result.webSearchCalls,
        citations: result.citations,
      );
      working.add(assistantToolCallMessage);

      final int displayAssistantCreatedAtMs =
          turn.assistantCreatedAt.millisecondsSinceEpoch;
      final int displayUserCreatedAtMs = _latestDisplayUserCreatedAtMs(display);
      liveUiThinkingJson = patchUiThinkingJsonWithToolUiEvent(
        liveUiThinkingJson,
        <String, dynamic>{
          'type': 'tool_batch_begin',
          'iteration': iters,
          'tools': await _buildUiToolsForToolCalls(
            result: result,
            cid: childCid,
            uiAssistantCreatedAtMs: displayAssistantCreatedAtMs,
            pinnedUserCreatedAtMs: displayUserCreatedAtMs,
          ),
        },
        assistantCreatedAtMs: displayAssistantCreatedAtMs,
        toolsTitle: _loc('工具调用', 'Tools'),
      );
      upsertDisplayAssistant(
        createdAt: turn.assistantCreatedAt,
        content: result.content,
        reasoning: result.reasoning,
        reasoningDuration: result.reasoningDuration,
        uiThinkingJson: liveUiThinkingJson,
        result: result,
      );
      await flushDisplaySave();

      final List<AIMessage> batchToolProtocolMessages = <AIMessage>[];
      final List<AIMessage> batchFollowUpMessages = <AIMessage>[];
      for (final AIToolCall call in result.toolCalls) {
        totalToolCalls += 1;
        final Stopwatch toolSw = Stopwatch()..start();
        final Map<String, String> localEvidencePathsForTool =
            <String, String>{};
        final List<AIMessage> rawToolMsgs =
            _isDelegateSubagentsTool(call) || _isAgentStatusTool(call)
            ? <AIMessage>[
                AIMessage(
                  role: 'tool',
                  toolCallId: call.id,
                  content: jsonEncode(<String, dynamic>{
                    'tool': call.name,
                    'ok': false,
                    'error': 'not_available_in_subagent',
                  }),
                ),
              ]
            : await _executeToolCall(
                call,
                conversationCid: childCid,
                assistantCreatedAtMs: displayAssistantCreatedAtMs,
                localEvidencePaths: localEvidencePathsForTool,
              );
        final List<AIMessage> toolMsgs = _compactToolMessagesForPrompt(
          rawToolMsgs,
          maxToolMessageTokens: AIChatService.maxToolMessageTokens,
          cid: childCid,
          stage: 'subagent_${task.id}_tool_result',
          model: modelForBudget,
        );
        toolSw.stop();
        batchToolProtocolMessages.addAll(
          toolMsgs.where((AIMessage message) => message.role == 'tool'),
        );
        batchFollowUpMessages.addAll(
          toolMsgs.where((AIMessage message) => message.role != 'tool'),
        );
        if (localEvidencePathsForTool.isNotEmpty) {
          liveEvidencePaths.addAll(localEvidencePathsForTool);
        }
        final String toolSummary = _summarizeToolMessages(toolMsgs);
        liveUiThinkingJson = patchUiThinkingJsonWithToolUiEvent(
          liveUiThinkingJson,
          <String, dynamic>{
            'type': 'tool_call_end',
            'call_id': call.id,
            'tool_name': call.name,
            'result_summary': toolSummary,
            'duration_ms': toolSw.elapsedMilliseconds,
            'detail_ref': _toolDetailRef(displayAssistantCreatedAtMs, call.id),
          },
          assistantCreatedAtMs: displayAssistantCreatedAtMs,
          toolsTitle: _loc('工具调用', 'Tools'),
        );
        upsertDisplayAssistant(
          createdAt: turn.assistantCreatedAt,
          content: result.content,
          reasoning: result.reasoning,
          reasoningDuration: result.reasoningDuration,
          uiThinkingJson: liveUiThinkingJson,
          result: result,
        );
        await flushDisplaySave();
        if (childCid.trim().isNotEmpty && call.id.trim().isNotEmpty) {
          await ScreenshotDatabase.instance.upsertAiToolCallDetail(
            conversationId: childCid.trim(),
            assistantCreatedAt: displayAssistantCreatedAtMs,
            callId: call.id,
            toolName: call.name,
            argumentsJson: call.argumentsJson,
            resultJson: _toolMessagesResultJson(rawToolMsgs),
            resultText: _toolMessagesResultText(rawToolMsgs),
            resultSummary: toolSummary,
            durationMs: toolSw.elapsedMilliseconds,
          );
        }
      }
      upsertDisplayAssistant(
        createdAt: turn.assistantCreatedAt,
        content: result.content,
        reasoning: result.reasoning,
        reasoningDuration: result.reasoningDuration,
        uiThinkingJson: liveUiThinkingJson,
        result: result,
      );
      await flushDisplaySave();

      working.addAll(batchToolProtocolMessages);
      working.addAll(batchFollowUpMessages);
      liveContent = '';
      turn = await runModelForDisplay(
        messages: working,
        toolsForCall: tools,
        toolChoiceForCall: toolChoice,
        trimStage: 'subagent_${task.id}_follow_$iters',
        isToolLoop: true,
      );
      result = turn.result;
    }

    if (result.toolCalls.isNotEmpty) {
      working.add(
        AIMessage(
          role: 'user',
          content:
              'Subagent tool loop reached its local iteration guard. Stop calling tools and provide the best answer from gathered results.',
        ),
      );
      liveContent = '';
      turn = await runModelForDisplay(
        messages: working,
        toolsForCall: const <Map<String, dynamic>>[],
        toolChoiceForCall: null,
        trimStage: 'subagent_${task.id}_final_no_tools',
        isToolLoop: false,
      );
      result = turn.result;
    }

    working.add(
      AIMessage(
        role: 'assistant',
        content: result.content,
        reasoningContent: result.reasoning,
        reasoningDuration: result.reasoningDuration,
        usagePromptTokens: result.usagePromptTokens,
        usageCompletionTokens: result.usageCompletionTokens,
        usageTotalTokens: result.usageTotalTokens,
        usageCacheHitTokens: result.usageCacheHitTokens,
        usageCacheMissTokens: result.usageCacheMissTokens,
        webSearchCalls: result.webSearchCalls,
        citations: result.citations,
      ),
    );
    liveUiThinkingJson = patchUiThinkingJsonFinish(
      liveUiThinkingJson,
      reasoningDuration: result.reasoningDuration,
    );
    upsertDisplayAssistant(
      createdAt: liveAssistantCreatedAt,
      content: liveContent.isNotEmpty ? liveContent : result.content,
      reasoning: liveReasoning.isNotEmpty ? liveReasoning : result.reasoning,
      reasoningDuration: result.reasoningDuration,
      uiThinkingJson: liveUiThinkingJson,
      result: result,
    );
    await flushDisplaySave();

    return _SubagentAgentRun(
      result: result,
      transcript: display,
      totalToolCalls: totalToolCalls,
    );
  }

  int _latestDisplayUserCreatedAtMs(List<AIMessage> messages) {
    for (int i = messages.length - 1; i >= 0; i--) {
      final AIMessage message = messages[i];
      if (message.role == 'user') {
        return message.createdAt.millisecondsSinceEpoch;
      }
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  List<AIMessage> _buildSubagentMessages(
    _SubagentTask task, {
    required List<AIMessage> rootMessages,
    required String userTask,
    String peerResultsContext = '',
  }) {
    final String context = _subagentRootContext(rootMessages);
    final String timeContext = _currentDateTimeSystemMessageForLocale();
    final String peerContext = peerResultsContext.trim();
    return <AIMessage>[
      AIMessage(
        role: 'system',
        content: [
          'You are a Codex-style child agent running inside ScreenMemo.',
          'Work only on the delegated task. You may call the provided tools when needed.',
          'You cannot create more subagents and you cannot update the main TODO list.',
          'Do not ask the user questions unless the task is impossible without one key missing fact.',
          'Return a concise summary with evidence, risks, and next steps when relevant.',
          if (timeContext.isNotEmpty) timeContext,
          'Resolve relative ranges such as 最近一周 / last week / recent week using the current device-local datetime above.',
          'Role: ${task.role}.',
          if (task.instructions.isNotEmpty)
            'Instructions: ${task.instructions}',
        ].join('\n'),
      ),
      AIMessage(
        role: 'user',
        content: [
          'Subagent context:',
          'Name: ${task.name}',
          'Role: ${task.role}',
          if (task.instructions.isNotEmpty)
            'Instructions: ${task.instructions}',
          '',
          'Main user request:',
          userTask.trim().isEmpty ? '(not provided)' : userTask.trim(),
          '',
          'Delegated task:',
          task.task,
          if (context.isNotEmpty) ...<String>[
            '',
            'Main-thread context:',
            context,
          ],
          if (peerContext.isNotEmpty) ...<String>[
            '',
            'Peer subagent results available for review:',
            peerContext,
            '',
            'If your role is reviewer, verify these peer results and call out gaps, disagreements, or missing evidence.',
          ],
        ].join('\n'),
      ),
    ];
  }

  Future<int?> _resolveSubagentProviderId(String parentConversationCid) async {
    final String parentCid = parentConversationCid.trim();
    try {
      if (parentCid.isNotEmpty) {
        final Map<String, dynamic>? parent = await ScreenshotDatabase.instance
            .getAiConversationByCid(parentCid);
        final Object? parentProviderId = parent?['provider_id'];
        if (parentProviderId is int && parentProviderId > 0) {
          return parentProviderId;
        }
        if (parentProviderId is num && parentProviderId > 0) {
          return parentProviderId.toInt();
        }
      }
    } catch (_) {}
    try {
      final Map<String, dynamic>? ctx = await ScreenshotDatabase.instance
          .getAIContext('chat');
      final Object? providerId = ctx?['provider_id'];
      if (providerId is int && providerId > 0) return providerId;
      if (providerId is num && providerId > 0) return providerId.toInt();
    } catch (_) {}
    return null;
  }

  bool _isReviewerSubagentTask(_SubagentTask task) {
    if (task.role.trim().toLowerCase() == 'reviewer') return true;
    final String text = [
      task.name,
      task.task,
      task.instructions,
    ].join('\n').toLowerCase();
    return text.contains('review') ||
        text.contains('audit') ||
        text.contains('verify') ||
        text.contains('risk') ||
        text.contains('审查') ||
        text.contains('评审') ||
        text.contains('复核') ||
        text.contains('验证') ||
        text.contains('风险');
  }

  String _subagentPeerResultsContext(List<_SubagentResult> results) {
    if (results.isEmpty) return '';
    final List<String> lines = <String>[];
    for (final _SubagentResult result in results) {
      final String status = result.ok ? 'ok' : 'failed';
      final String body = result.ok ? result.content : (result.error ?? '');
      lines.add(
        [
          '- ${result.task.name} (${result.task.role}, $status)',
          if (result.model.trim().isNotEmpty) 'model=${result.model}',
          if (result.conversationCid.trim().isNotEmpty)
            'conversation_cid=${result.conversationCid}',
          'result=${_clipLine(body, maxLen: 900)}',
        ].join(' · '),
      );
    }
    return lines.join('\n');
  }

  List<AIMessage> _buildSubagentDisplayMessages(_SubagentTask task) {
    final List<String> lines = <String>['Delegated task:', task.task];
    if (task.instructions.isNotEmpty) {
      lines.addAll(<String>['', 'Instructions:', task.instructions]);
    }
    return <AIMessage>[AIMessage(role: 'user', content: lines.join('\n'))];
  }

  String _subagentRootContext(List<AIMessage> rootMessages) {
    final Iterable<AIMessage> tail = rootMessages
        .where((AIMessage m) => m.role == 'user' || m.role == 'assistant')
        .toList(growable: false)
        .reversed
        .take(6)
        .toList(growable: false)
        .reversed;
    final List<String> chunks = <String>[];
    for (final AIMessage message in tail) {
      final String content = _clipLine(message.providerContent, maxLen: 900);
      if (content.isEmpty) continue;
      chunks.add('${message.role}: $content');
    }
    return chunks.join('\n');
  }

  int _contextPercent(int tokens, int cap) {
    if (tokens <= 0 || cap <= 0) return 0;
    return ((tokens * 100) / cap).round().clamp(0, 999);
  }

  String _summarizeSubagentResults(List<_SubagentResult> results) {
    if (results.isEmpty) return 'No subagent results.';
    final List<String> lines = <String>[];
    for (final _SubagentResult result in results) {
      final String status = result.ok ? 'ok' : 'failed';
      final String body = result.ok ? result.content : (result.error ?? '');
      lines.add(
        '- ${result.task.name} [$status]: ${_clipLine(body, maxLen: 420)}',
      );
    }
    return lines.join('\n');
  }

  String _normalizeSubagentId(String value) {
    final String normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return normalized.length <= 48 ? normalized : normalized.substring(0, 48);
  }

  String _defaultSubagentName(String role, String id) {
    final String suffix = id.replaceAll('_', ' ');
    return switch (role) {
      'worker' => 'Worker $suffix',
      'reviewer' => 'Reviewer $suffix',
      _ => 'Explorer $suffix',
    };
  }
}
