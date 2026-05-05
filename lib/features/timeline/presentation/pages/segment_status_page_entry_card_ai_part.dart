part of 'segment_status_page.dart';

// ========== 单条动态 AI 重试与流式展示 ==========
extension _SegmentEntryCardAiPart on _SegmentEntryCardState {
  String _buildAiRequestResponseTraceText({
    required int segmentId,
    required String timeLabel,
    Map<String, dynamic>? result,
  }) {
    final String provider = (result?['ai_provider'] as String?)?.trim() ?? '';
    final String model = (result?['ai_model'] as String?)?.trim() ?? '';
    final String rawRequest =
        (result?['raw_request'] as String?)?.trimRight() ?? '';
    final String rawResponse =
        (result?['raw_response'] as String?)?.trimRight() ?? '';
    final int createdAtMs = (result?['created_at'] as int?) ?? 0;
    final String createdAtText = createdAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(createdAtMs).toIso8601String()
        : '';

    final StringBuffer sb = StringBuffer();
    sb.writeln('AI Request/Response Trace');
    sb.writeln('segment_id: $segmentId');
    if (timeLabel.trim().isNotEmpty) sb.writeln('time_range: $timeLabel');
    if (provider.isNotEmpty) sb.writeln('provider: $provider');
    if (model.isNotEmpty) sb.writeln('model: $model');
    if (createdAtText.isNotEmpty) sb.writeln('created_at: $createdAtText');
    sb.writeln('');
    sb.writeln('--- request ---');
    sb.writeln(rawRequest.isEmpty ? '(empty)' : rawRequest);
    sb.writeln('');
    sb.writeln('--- response ---');
    sb.writeln(rawResponse.isEmpty ? '(empty)' : rawResponse);
    return sb.toString().trimRight();
  }

  Future<void> _saveAiRequestResponseTraceToFile({
    required int segmentId,
    required String text,
  }) async {
    final String content = text.trimRight();
    if (content.trim().isEmpty) return;
    try {
      final DateTime now = DateTime.now();
      String? baseDirPath;
      try {
        baseDirPath = await FlutterLogger.getTodayLogsDir();
      } catch (_) {
        baseDirPath = null;
      }
      Directory baseDir = Directory.systemTemp;
      if (baseDirPath != null && baseDirPath.trim().isNotEmpty) {
        baseDir = Directory(baseDirPath.trim());
      }
      final String sep = Platform.pathSeparator;
      final Directory outDir = Directory(
        '${baseDir.path}${sep}ai_segment_traces',
      );
      await outDir.create(recursive: true);
      final File f = File(
        '${outDir.path}${sep}segment_ai_trace_${segmentId}_${now.millisecondsSinceEpoch}.log',
      );
      await f.writeAsString('$content\n', flush: true);
      try {
        await Clipboard.setData(ClipboardData(text: f.path));
      } catch (_) {}
      if (!mounted) return;
      UINotifier.success(
        context,
        AppLocalizations.of(context).savedToPath(f.path),
      );
    } catch (e) {
      if (!mounted) return;
      UINotifier.error(
        context,
        AppLocalizations.of(context).saveFailedError(e.toString()),
      );
    }
  }

  Widget _buildAiRequestResponseSheetBody({
    required BuildContext context,
    required int segmentId,
    required String rawRequest,
    required String rawResponse,
    required String provider,
    required String model,
    required DateTime? createdAt,
    required bool isZh,
    required bool hasAny,
    required String visibleText,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double fallbackHeight = MediaQuery.of(context).size.height * 0.62;
        final double viewerHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : fallbackHeight;
        return AIRequestLogsViewer.fromSegmentTrace(
          rawRequest: rawRequest,
          rawResponse: rawResponse,
          segmentId: segmentId,
          provider: provider,
          model: model,
          createdAt: createdAt,
          showRawResponsePanel: false,
          scrollable: true,
          maxHeight: viewerHeight,
          emptyText: isZh ? '（暂无请求/响应记录）' : '(No request/response trace yet)',
          actions: <AIRequestLogsAction>[
            AIRequestLogsAction(
              label: AppLocalizations.of(context).actionCopy,
              enabled: hasAny,
              onPressed: () async {
                if (!hasAny) return;
                try {
                  await Clipboard.setData(ClipboardData(text: visibleText));
                  if (!mounted) return;
                  UINotifier.success(
                    this.context,
                    AppLocalizations.of(this.context).copySuccess,
                  );
                } catch (_) {}
              },
            ),
            AIRequestLogsAction(
              label: isZh ? '保存到文件' : 'Save to file',
              enabled: hasAny,
              onPressed: () async {
                if (!hasAny) return;
                await _saveAiRequestResponseTraceToFile(
                  segmentId: segmentId,
                  text: visibleText,
                );
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAiRequestResponseSheet(
    int segmentId, {
    required String timeLabel,
  }) async {
    Map<String, dynamic>? res;
    try {
      res = await widget.loadResult(segmentId);
    } catch (_) {
      res = null;
    }
    if (!mounted) return;

    final bool isZh = Localizations.localeOf(
      context,
    ).languageCode.toLowerCase().startsWith('zh');
    final String provider = (res?['ai_provider'] as String?)?.trim() ?? '';
    final String model = (res?['ai_model'] as String?)?.trim() ?? '';
    final int createdAtMs = (res?['created_at'] as int?) ?? 0;
    final DateTime? createdAt = createdAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(createdAtMs)
        : null;
    final String rawRequest = (res?['raw_request'] as String?)?.trim() ?? '';
    final String rawResponse = (res?['raw_response'] as String?)?.trim() ?? '';
    final bool hasTrace = rawRequest.isNotEmpty || rawResponse.isNotEmpty;
    final String text = _buildAiRequestResponseTraceText(
      segmentId: segmentId,
      timeLabel: timeLabel,
      result: res,
    );
    final String emptyHint = isZh
        ? '（暂无请求/响应记录。升级后需要重新生成一次摘要才会写入。）'
        : '(No request/response trace yet. Regenerate once to capture it.)';
    final String visibleText = hasTrace
        ? text
        : (('$emptyHint\n\n$text').trimRight());
    final bool hasAny = visibleText.trim().isNotEmpty;
    await AIRequestLogsSheet.show(
      context: context,
      title: isZh ? 'AI 日志' : 'AI Logs',
      metaText: null,
      hintText: hasTrace ? null : emptyHint,
      expandBody: true,
      body: _buildAiRequestResponseSheetBody(
        context: context,
        segmentId: segmentId,
        rawRequest: rawRequest,
        rawResponse: rawResponse,
        provider: provider,
        model: model,
        createdAt: createdAt,
        isZh: isZh,
        hasAny: hasAny,
        visibleText: visibleText,
      ),
    );
  }

  Future<void> _retry() async {
    final int id = (_segmentData['id'] as int?) ?? 0;
    if (id <= 0 || _retrying) return;
    if (widget.dynamicRebuildActive) {
      UINotifier.info(
        context,
        AppLocalizations.of(context).dynamicRebuildBlockedRetry,
      );
      return;
    }
    final previous = Map<String, dynamic>.from(_segmentData);
    int? previousCreatedAt = _lastResultCreatedAt;
    try {
      final prevRes = await widget.loadResult(id);
      final loaded = (prevRes?['created_at'] as int?) ?? 0;
      if (loaded > 0) {
        previousCreatedAt = loaded;
      }
    } catch (_) {}
    if (!mounted) return;
    final cleared = _segmentWithoutResult(previous);
    _entryCardSetState(() {
      _retrying = true;
      _segmentData = cleared;
      _lastResultCreatedAt = previousCreatedAt;
      _summaryStreaming = true;
      _summaryStreamingText = _summaryGeneratingPlaceholder;
    });
    try {
      // 手动重试不受时间/已有结果限制：强制重跑
      final n = await ScreenshotDatabase.instance.retrySegments([
        id,
      ], force: true);
      if (!mounted) return;
      final ok = n > 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? AppLocalizations.of(context).regenerationQueued
                : AppLocalizations.of(context).alreadyQueuedOrFailed,
          ),
        ),
      );
      // 开启轮询直到拿到结果为止；若原本就有结果，可能立即返回
      if (ok) _startResultWatch(id);
      // 如果没成功入队，停止旋转
      if (!ok) {
        _entryCardSetState(() {
          _retrying = false;
          _segmentData = Map<String, dynamic>.from(previous);
          _lastResultCreatedAt = previousCreatedAt;
          _summaryStreaming = false;
          _summaryStreamingText = '';
        });
      }
    } catch (_) {
      if (!mounted) return;
      _entryCardSetState(() {
        _retrying = false;
        _segmentData = Map<String, dynamic>.from(previous);
        _lastResultCreatedAt = previousCreatedAt;
        _summaryStreaming = false;
        _summaryStreamingText = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).retryFailed)),
      );
    }
  }

  Future<void> _forceMerge() async {
    final int id = (_segmentData['id'] as int?) ?? 0;
    if (id <= 0 || _forcingMerge) return;
    if (widget.dynamicRebuildActive) {
      UINotifier.info(
        context,
        AppLocalizations.of(context).dynamicRebuildBlockedForceMerge,
      );
      return;
    }
    final int prevId = (_segmentData['merge_prev_id'] as int?) ?? 0;
    if (prevId <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).forceMergeNoPrevious),
        ),
      );
      return;
    }

    final bool confirmed =
        await showUIDialog<bool>(
          context: context,
          title: AppLocalizations.of(context).forceMerge,
          message: AppLocalizations.of(context).forceMergeConfirmMessage,
          actions: [
            UIDialogAction<bool>(
              text: AppLocalizations.of(context).dialogCancel,
              style: UIDialogActionStyle.normal,
              result: false,
            ),
            UIDialogAction<bool>(
              text: AppLocalizations.of(context).forceMerge,
              style: UIDialogActionStyle.destructive,
              result: true,
            ),
          ],
          barrierDismissible: true,
        ) ??
        false;
    if (!confirmed) return;

    int? previousCreatedAt = _lastMergeResultCreatedAt;
    try {
      final prevRes = await widget.loadResult(id);
      final loaded = (prevRes?['created_at'] as int?) ?? 0;
      if (loaded > 0) previousCreatedAt = loaded;
    } catch (_) {}

    if (!mounted) return;
    _entryCardSetState(() {
      _forcingMerge = true;
      _segmentData = Map<String, dynamic>.from(_segmentData)
        ..['merge_forced'] = 1
        ..['merge_decision_reason'] = AppLocalizations.of(
          context,
        ).forceMergeRequestedReason;
      _lastMergeResultCreatedAt = previousCreatedAt;
    });

    try {
      final ok = await ScreenshotDatabase.instance.forceMergeSegment(
        id,
        prevId: prevId,
      );
      if (!mounted) return;
      if (!ok) {
        _entryCardSetState(() => _forcingMerge = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).forceMergeQueuedFailed),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).forceMergeQueued)),
      );
      _startMergeWatch(id, previousCreatedAt);
    } catch (_) {
      if (!mounted) return;
      _entryCardSetState(() => _forcingMerge = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).forceMergeFailed)),
      );
    }
  }

  Future<void> _confirmAndDelete() async {
    final int id = (_segmentData['id'] as int?) ?? 0;
    if (id <= 0) return;

    final bool confirmed =
        await showUIDialog<bool>(
          context: context,
          title: AppLocalizations.of(context).deleteEventTooltip,
          message: AppLocalizations.of(context).confirmDeleteEventMessage,
          actions: [
            UIDialogAction<bool>(
              text: AppLocalizations.of(context).dialogCancel,
              style: UIDialogActionStyle.normal,
              result: false,
            ),
            UIDialogAction<bool>(
              text: AppLocalizations.of(context).actionDelete,
              style: UIDialogActionStyle.destructive,
              result: true,
            ),
          ],
          barrierDismissible: true,
        ) ??
        false;

    if (!confirmed) return;
    try {
      final ok = await ScreenshotDatabase.instance.deleteSegmentOnly(id);
      if (!mounted) return;
      if (ok) {
        UINotifier.success(
          context,
          AppLocalizations.of(context).eventDeletedToast,
        );
        await widget.onRefreshRequested();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).deleteFailed)),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).deleteFailed)),
      );
    }
  }

  void _startResultWatch(int id, {bool notifyToast = true}) {
    _resultWatchTimer?.cancel();
    // 轮询间隔 2s；若拿到结果则停止旋转
    _resultWatchTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      try {
        final res = await widget.loadResult(id);
        if (!mounted) return;
        if (res != null) {
          final int newCreatedAt = (res['created_at'] as int?) ?? 0;
          if (_lastResultCreatedAt != null &&
              newCreatedAt > 0 &&
              newCreatedAt <= _lastResultCreatedAt!) {
            return;
          }
          t.cancel();
          final merged = _mergeResultIntoSegment(_segmentData, res);
          final String finalSummary = _extractOverallSummary(
            _tryParseJson(merged['structured_json'] as String?),
          );
          _entryCardSetState(() {
            _retrying = false;
            _segmentData = merged;
            _lastResultCreatedAt = newCreatedAt > 0
                ? newCreatedAt
                : _lastResultCreatedAt;
            _summaryStreaming = true;
            _summaryStreamingText = '';
          });
          _latestExternalSegment = Map<String, dynamic>.from(merged);
          if (notifyToast) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(AppLocalizations.of(context).generateSuccess),
              ),
            );
          }
          _beginSummaryStreaming(finalSummary);
          try {
            await widget.onRefreshRequested();
          } catch (_) {}
        }
      } catch (_) {
        // 读取失败不影响轮询，继续尝试
      }
    });
  }

  void _startMergeWatch(int id, int? previousCreatedAt) {
    _mergeWatchTimer?.cancel();
    _mergeWatchTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      try {
        final res = await widget.loadResult(id);
        if (!mounted) return;
        if (res == null) return;
        final int newCreatedAt = (res['created_at'] as int?) ?? 0;
        if (previousCreatedAt != null &&
            newCreatedAt > 0 &&
            newCreatedAt <= previousCreatedAt) {
          return;
        }
        t.cancel();
        final mergedSeg = _mergeResultIntoSegment(_segmentData, res);
        final String finalSummary = _extractOverallSummary(
          _tryParseJson(mergedSeg['structured_json'] as String?),
        );
        _entryCardSetState(() {
          _forcingMerge = false;
          _segmentData = mergedSeg;
          _lastMergeResultCreatedAt = newCreatedAt > 0
              ? newCreatedAt
              : _lastMergeResultCreatedAt;
          _summaryStreaming = true;
          _summaryStreamingText = '';
        });
        _latestExternalSegment = Map<String, dynamic>.from(mergedSeg);
        _beginSummaryStreaming(finalSummary);
        try {
          await widget.onRefreshRequested();
        } catch (_) {}
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).mergeCompleted)),
        );
      } catch (_) {}
    });
  }

  void _beginSummaryStreaming(String target) {
    _summaryStreamTimer?.cancel();
    if (!mounted) return;
    if (target.trim().isEmpty) {
      _entryCardSetState(() {
        _summaryStreaming = false;
        _summaryStreamingText = target;
      });
      return;
    }
    _entryCardSetState(() {
      _summaryStreaming = true;
      _summaryStreamingText = '';
    });
    const int chunkSize = 24;
    int idx = 0;
    _summaryStreamTimer = Timer.periodic(const Duration(milliseconds: 35), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      idx = math.min(idx + chunkSize, target.length);
      final String next = target.substring(0, idx);
      _entryCardSetState(() {
        _summaryStreamingText = next;
      });
      if (idx >= target.length) {
        timer.cancel();
        _entryCardSetState(() {
          _summaryStreaming = false;
        });
      }
    });
  }
}
