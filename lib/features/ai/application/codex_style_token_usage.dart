/// Codex-style token usage view derived from provider usage or local prompt
/// estimates.
class CodexStyleTokenUsage {
  const CodexStyleTokenUsage({
    required this.inputTokens,
    required this.cachedInputTokens,
    required this.outputTokens,
    required this.reasoningOutputTokens,
    required this.totalTokens,
    required this.source,
  });

  static const int baselineTokens = 12000;

  final int inputTokens;
  final int cachedInputTokens;
  final int outputTokens;
  final int reasoningOutputTokens;
  final int totalTokens;
  final String source;

  factory CodexStyleTokenUsage.zero({String source = 'none'}) {
    return CodexStyleTokenUsage(
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      reasoningOutputTokens: 0,
      totalTokens: 0,
      source: source,
    );
  }

  factory CodexStyleTokenUsage.fromValues({
    required int inputTokens,
    required int cachedInputTokens,
    required int outputTokens,
    required int reasoningOutputTokens,
    int? totalTokens,
    required String source,
  }) {
    final int input = inputTokens.clamp(0, 1 << 62).toInt();
    final int cached = cachedInputTokens.clamp(0, input).toInt();
    final int output = outputTokens.clamp(0, 1 << 62).toInt();
    final int reasoning = reasoningOutputTokens.clamp(0, 1 << 62).toInt();
    final int total = (totalTokens ?? (input + output))
        .clamp(0, 1 << 62)
        .toInt();
    return CodexStyleTokenUsage(
      inputTokens: input,
      cachedInputTokens: cached,
      outputTokens: output,
      reasoningOutputTokens: reasoning,
      totalTokens: total,
      source: source.trim().isEmpty ? 'estimate' : source.trim(),
    );
  }

  int get nonCachedInputTokens =>
      (inputTokens - cachedInputTokens).clamp(0, 1 << 62).toInt();

  int get blendedTotalTokens =>
      (nonCachedInputTokens + outputTokens).clamp(0, 1 << 62).toInt();

  int get tokensInContextWindow => totalTokens;

  double contextRemainingRatio(int contextWindow) {
    if (contextWindow <= baselineTokens) return 0;
    final int effectiveWindow = contextWindow - baselineTokens;
    final int used = (tokensInContextWindow - baselineTokens)
        .clamp(0, effectiveWindow)
        .toInt();
    final int remaining = (effectiveWindow - used).clamp(0, effectiveWindow);
    return (remaining / effectiveWindow).clamp(0.0, 1.0);
  }

  double contextUsedRatio(int contextWindow) {
    return (1.0 - contextRemainingRatio(contextWindow)).clamp(0.0, 1.0);
  }

  CodexStyleTokenUsage plus(CodexStyleTokenUsage other) {
    return CodexStyleTokenUsage.fromValues(
      inputTokens: inputTokens + other.inputTokens,
      cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
      outputTokens: outputTokens + other.outputTokens,
      reasoningOutputTokens:
          reasoningOutputTokens + other.reasoningOutputTokens,
      totalTokens: totalTokens + other.totalTokens,
      source: source == 'usage' && other.source == 'usage' ? 'usage' : 'mixed',
    );
  }
}

class CodexStyleTokenUsageInfo {
  const CodexStyleTokenUsageInfo({
    required this.totalTokenUsage,
    required this.lastTokenUsage,
    required this.modelContextWindow,
    required this.eventsCount,
    required this.usageBackedCount,
  });

  final CodexStyleTokenUsage totalTokenUsage;
  final CodexStyleTokenUsage lastTokenUsage;
  final int? modelContextWindow;
  final int eventsCount;
  final int usageBackedCount;

  double get usageCoverage =>
      eventsCount <= 0 ? 0 : (usageBackedCount / eventsCount);
}
