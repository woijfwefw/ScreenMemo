part of 'ai_chat_service.dart';

extension AIChatServiceToolLoopEventsExt on AIChatService {
  Future<List<Map<String, dynamic>>> _buildUiToolsForToolCalls({
    required AIGatewayResult result,
    required String cid,
    required int? uiAssistantCreatedAtMs,
    required int pinnedUserCreatedAtMs,
  }) async {
    return Future.wait(
      result.toolCalls
          .map((c) async {
            final Map<String, dynamic> args = _safeJsonObject(c.argumentsJson);
            final List<String> appNames = _normalizeAppNamesArg(args);
            final List<String> appPkgs = await _resolveAppPackagesFromArgs(
              args,
            );
            final String detailRef = _toolDetailRef(
              uiAssistantCreatedAtMs ?? 0,
              c.id,
            );
            if (cid.isNotEmpty &&
                (uiAssistantCreatedAtMs ?? 0) > 0 &&
                c.id.trim().isNotEmpty &&
                !_isConversationPersistenceBlockedOrStale(
                  cid: cid,
                  createdAtMs: pinnedUserCreatedAtMs,
                )) {
              final int assistantAt = uiAssistantCreatedAtMs!;
              unawaited(() async {
                if (_isConversationPersistenceBlockedOrStale(
                  cid: cid,
                  createdAtMs: pinnedUserCreatedAtMs,
                )) {
                  return;
                }
                await ScreenshotDatabase.instance.upsertAiToolCallDetail(
                  conversationId: cid,
                  assistantCreatedAt: assistantAt,
                  callId: c.id,
                  toolName: c.name,
                  argumentsJson: c.argumentsJson,
                  clearResult: true,
                );
              }());
            }
            return <String, dynamic>{
              'call_id': c.id,
              'tool_name': c.name,
              'label': _toolCallUiLabel(c),
              if (detailRef.isNotEmpty) 'detail_ref': detailRef,
              if (appNames.isNotEmpty) 'app_names': appNames,
              if (appPkgs.isNotEmpty) 'app_package_names': appPkgs,
              if (c.name == 'generate_image')
                'generated_image_loading_count':
                    AIImageGenerationParams.normalizeCount(args['count']),
            };
          })
          .toList(growable: false),
    );
  }

  void _emitToolBatchUiEvents({
    required void Function(AIStreamEvent event)? emitEvent,
    required List<Map<String, dynamic>> uiTools,
    required int iters,
  }) {
    for (final Map<String, dynamic> uiTool in uiTools) {
      if ((uiTool['tool_name'] as String?)?.trim() != 'generate_image') {
        continue;
      }
      unawaited(
        FlutterLogger.nativeInfo(
          'AI_IMAGE',
          'tool.batch_begin call=${uiTool['call_id']} loadingCount=${uiTool['generated_image_loading_count']}',
        ),
      );
    }
    _emitUi(emitEvent, <String, dynamic>{
      'type': 'tool_batch_begin',
      'iteration': iters,
      'tools': uiTools,
    });
  }

  void _emitToolCompletionUiEvent({
    required void Function(AIStreamEvent event)? emitEvent,
    required AIToolCall call,
    required String toolSummary,
    required int durationMs,
    required int? uiAssistantCreatedAtMs,
    required Map<String, dynamic>? toolPayloadForUi,
    required List<String> generatedImageMarkersForUi,
  }) {
    _emitUi(emitEvent, <String, dynamic>{
      'type': 'tool_call_end',
      'call_id': call.id,
      'tool_name': call.name,
      'result_summary': toolSummary,
      'duration_ms': durationMs,
      'detail_ref': _toolDetailRef(uiAssistantCreatedAtMs ?? 0, call.id),
      if (toolPayloadForUi != null &&
          (toolPayloadForUi['tool'] as String?)?.trim() == 'generate_image')
        'generated_image_markers': generatedImageMarkersForUi,
    });
  }
}
