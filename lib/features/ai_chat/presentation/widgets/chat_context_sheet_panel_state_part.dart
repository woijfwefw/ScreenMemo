part of 'chat_context_sheet.dart';

extension _ChatContextPanelStatePart on _ChatContextPanelState {
  void _refreshSnapshotOnly() {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    final Future<ChatContextSnapshot> snapFuture = ChatContextService.instance
        .getSnapshot();
    snapFuture
        .then((s) {
          _cachedSnapshot = s;
          unawaited(() async {
            try {
              final List<ChatContextEvent> events = await ChatContextService
                  .instance
                  .listRecentContextEvents(
                    cid: s.cid,
                    type: 'prompt_trim',
                    limit: _ChatContextPanelState._trimEventsDefaultLimit,
                  );
              if (!mounted) return;
              _panelSetState(() {
                _cachedTrimEvents = events;
              });
            } catch (_) {}
            try {
              final List<PromptUsageEvent> usageEvents =
                  await ChatContextService.instance.listPromptUsageEvents(
                    cid: s.cid,
                    limit: 1,
                  );
              final PromptUsageEvent? latest = usageEvents.isEmpty
                  ? null
                  : usageEvents.first;
              if (!mounted) return;
              _panelSetState(() {
                _cachedLatestUsage = latest;
              });
            } catch (_) {}
            try {
              final CodexStyleTokenUsageInfo info = await ChatContextService
                  .instance
                  .getCodexStyleTokenUsageInfo(
                    cid: s.cid,
                    modelContextWindow: _activeModelContextTokens,
                  );
              if (!mounted) return;
              _panelSetState(() {
                _cachedCodexUsageInfo = info;
              });
            } catch (_) {}
          }());
          try {
            final String raw = s.lastPromptBreakdownJson.trim();
            if (raw.isEmpty) return;
            final dynamic decoded = jsonDecode(raw);
            if (decoded is! Map) return;
            final String m = (decoded['model'] ?? '').toString().trim();
            if (m.isEmpty) return;
            if (m == _lastPromptModelForCapOverride) return;
            _lastPromptModelForCapOverride = m;
            unawaited(() async {
              final int? v = await AIModelPromptCapsService.instance
                  .getOverride(m);
              if (!mounted) return;
              // Only rebuild if we actually have a custom override (otherwise
              // the default inference stays the same).
              if (v != null) _panelSetState(() {});
            }());
          } catch (_) {}
        })
        .catchError((_) {});
    snapFuture.whenComplete(() {
      _refreshInFlight = false;
    });
    _panelSetState(() {
      _future = snapFuture;
    });
  }

  void _reload() {
    _refreshSnapshotOnly();
    _loadModelInfo();
  }
}
