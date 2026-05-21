import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_memo/features/ai/application/chat_context_service.dart';
import 'package:screen_memo/features/ai/application/codex_style_token_usage.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _prepareDesktopDbRoot(Directory root) async {
  await ScreenshotDatabase.instance.initializeForDesktop(root.path);
  final db = await ScreenshotDatabase.instance.database;
  await db.insert('ai_conversations', <String, Object?>{
    'cid': 'usage-cid',
    'title': 'usage-test',
    'created_at': DateTime.now().millisecondsSinceEpoch,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('record/list prompt usage events and totals', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'screen_memo_prompt_usage_',
    );
    try {
      final Directory root = Directory(p.join(tmp.path, 'root'));
      await root.create(recursive: true);
      await _prepareDesktopDbRoot(root);

      await ChatContextService.instance.recordPromptUsageEvent(
        cid: 'usage-cid',
        model: 'gpt-test',
        promptEstBefore: 120,
        promptEstSent: 100,
        usagePromptTokens: null,
        usageCompletionTokens: null,
        usageTotalTokens: null,
        usageCacheHitTokens: null,
        usageCacheMissTokens: null,
        isToolLoop: false,
        includeHistory: true,
        toolsCount: 0,
        strictFullAttempted: true,
        fallbackTriggered: true,
        breakdownJson:
            '{"parts":{"history_user":40},"completion_estimate":12,"total_estimate":112}',
      );

      await ChatContextService.instance.recordPromptUsageEvent(
        cid: 'usage-cid',
        model: 'gpt-test',
        promptEstBefore: 230,
        promptEstSent: 210,
        usagePromptTokens: 200,
        usageCompletionTokens: 80,
        usageTotalTokens: 280,
        usageCacheHitTokens: 120,
        usageCacheMissTokens: 80,
        isToolLoop: true,
        includeHistory: true,
        toolsCount: 2,
        strictFullAttempted: true,
        fallbackTriggered: false,
        breakdownJson: '{"parts":{"history_tool":50}}',
      );

      final List<PromptUsageEvent> events = await ChatContextService.instance
          .listPromptUsageEvents(cid: 'usage-cid', limit: 10);
      expect(events.length, 2);
      expect(events.first.model, 'gpt-test');
      expect(events.first.isToolLoop, isTrue);
      expect(events.first.hasUsage, isTrue);
      expect(events.first.usageCacheHitTokens, 120);
      expect(events.first.usageCacheMissTokens, 80);

      final PromptUsageTotals totals = await ChatContextService.instance
          .getConversationPromptUsageTotals(cid: 'usage-cid');
      expect(totals.eventsCount, 2);
      expect(totals.usageBackedCount, 1);
      expect(totals.promptTokens, 300); // 100(est) + 200(usage)
      expect(totals.completionTokens, 92); // 12(est) + 80(usage)
      expect(totals.totalTokens, 392); // 112(est) + 280(usage)
      expect(totals.cacheHitTokens, 120);
      expect(totals.cacheMissTokens, 80);

      final CodexStyleTokenUsageInfo codexUsage = await ChatContextService
          .instance
          .getCodexStyleTokenUsageInfo(
            cid: 'usage-cid',
            modelContextWindow: 128000,
          );
      expect(codexUsage.eventsCount, 2);
      expect(codexUsage.usageBackedCount, 1);
      expect(codexUsage.modelContextWindow, 128000);
      expect(codexUsage.lastTokenUsage.inputTokens, 200);
      expect(codexUsage.lastTokenUsage.cachedInputTokens, 120);
      expect(codexUsage.lastTokenUsage.nonCachedInputTokens, 80);
      expect(codexUsage.lastTokenUsage.outputTokens, 80);
      expect(codexUsage.lastTokenUsage.blendedTotalTokens, 160);
      expect(codexUsage.lastTokenUsage.tokensInContextWindow, 280);
      expect(codexUsage.totalTokenUsage.inputTokens, 300);
      expect(codexUsage.totalTokenUsage.outputTokens, 92);
      expect(codexUsage.totalTokenUsage.blendedTotalTokens, 272);
      expect(codexUsage.lastTokenUsage.contextUsedRatio(128000), 0);
    } finally {
      try {
        await ScreenshotDatabase.instance.disposeDesktop();
      } catch (_) {}
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });
}
