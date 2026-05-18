import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';

const MethodChannel _platformChannel = MethodChannel(
  'com.fqyw.screen_memo/accessibility',
);

Map<String, Object?> _status({
  String taskMode = 'backfill',
  String status = 'running',
  String targetDayKey = '',
}) {
  return <String, Object?>{
    'taskId': status == 'idle' ? '' : 'dynamic_rebuild_test',
    'taskMode': taskMode,
    'status': status,
    'startedAt': 0,
    'updatedAt': 0,
    'completedAt': 0,
    'dayConcurrency': 1,
    'totalSegments': 0,
    'processedSegments': 0,
    'failedSegments': 0,
    'totalDays': 0,
    'completedDays': 0,
    'pendingDays': 0,
    'failedDays': 0,
    'currentDayKey': '',
    'targetDayKey': targetDayKey,
    'timelineCutoffDayKey': '',
    'currentSegmentId': 0,
    'currentRangeLabel': '',
    'currentStage': '',
    'currentStageLabel': '',
    'currentStageDetail': '',
    'lastError': null,
    'isActive': status == 'running',
    'progressPercent': '0%',
    'aiModel': '',
    'recentLogs': <String>[],
    'workers': <Object?>[],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_platformChannel, null);
  });

  test('DynamicRebuildTaskStatus.fromMap parses concurrent day fields', () {
    final DynamicRebuildTaskStatus status = DynamicRebuildTaskStatus.fromMap(
      <String, Object?>{
        'taskId': 'dynamic_rebuild_1',
        'taskMode': 'backfill',
        'status': 'completed_with_failures',
        'startedAt': 100,
        'updatedAt': 200,
        'completedAt': 300,
        'dayConcurrency': 3,
        'totalSegments': 9,
        'processedSegments': 6,
        'failedSegments': 1,
        'totalDays': 4,
        'completedDays': 2,
        'pendingDays': 2,
        'failedDays': 1,
        'currentDayKey': '2026-03-12',
        'targetDayKey': '2026-03-12',
        'timelineCutoffDayKey': '2026-03-13',
        'currentSegmentId': 42,
        'currentRangeLabel': '09:00:00-09:30:00',
        'currentStage': 'completed_with_failures',
        'currentStageLabel': '部分完成',
        'currentStageDetail': '仍有失败日期待继续',
        'lastError': 'some error',
        'isActive': false,
        'progressPercent': '66.7%',
        'aiModel': 'gpt-4.1',
        'recentLogs': <String>['[T1][2026-03-12] 当前动态完成'],
        'workers': <Object?>[
          <String, Object?>{
            'slotId': 1,
            'status': 'running',
            'dayKey': '2026-03-12',
            'totalSegments': 3,
            'processedSegments': 1,
            'currentRangeLabel': '09:00:00-09:30:00',
            'currentStageLabel': '等待 AI 总结',
            'currentStageDetail': '已准备请求模型',
            'currentSegmentId': 42,
            'retryCount': 0,
            'retryLimit': 3,
            'recentStreamChunks': <String>[
              '最旧流式文本',
              '第一段流式文本',
              '第二段流式文本',
              '第三段流式文本',
            ],
          },
          <String, Object?>{
            'slotId': 2,
            'status': 'failed_waiting',
            'dayKey': '2026-03-10',
            'totalSegments': 2,
            'processedSegments': 1,
            'currentRangeLabel': '',
            'currentStageLabel': '等待手动继续',
            'currentStageDetail': '已达到自动续跑上限',
            'currentSegmentId': 0,
            'retryCount': 3,
            'retryLimit': 3,
            'recentStreamChunks': <String>[],
          },
        ],
      },
    );

    expect(status.dayConcurrency, 3);
    expect(status.taskMode, 'backfill');
    expect(status.isBackfillMode, isTrue);
    expect(status.targetDayKey, '2026-03-12');
    expect(status.totalDays, 4);
    expect(status.completedDays, 2);
    expect(status.pendingDays, 2);
    expect(status.failedDays, 1);
    expect(status.timelineCutoffDayKey, '2026-03-13');
    expect(status.isCompletedWithFailures, isTrue);
    expect(status.canContinue, isTrue);
    expect(status.workers, hasLength(2));
    expect(status.workers.first.slotId, 1);
    expect(status.workers.first.dayKey, '2026-03-12');
    expect(status.workers.first.recentStreamChunks, <String>[
      '第一段流式文本',
      '第二段流式文本',
      '第三段流式文本',
    ]);
    expect(status.workers.first.recentStreamChunks.last, '第三段流式文本');
    expect(status.workers.last.isFailedWaiting, isTrue);
    expect(status.recentLogs.single, contains('[T1][2026-03-12]'));
  });

  test('startDynamicRebuildTask sends targetDayKey when provided', () async {
    Map<dynamic, dynamic>? capturedArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_platformChannel, (MethodCall call) async {
          expect(call.method, 'startDynamicRebuildTask');
          capturedArgs = call.arguments as Map<dynamic, dynamic>?;
          return _status(targetDayKey: '2024-04-10');
        });

    final DynamicRebuildTaskStatus status = await ScreenshotDatabase.instance
        .startDynamicRebuildTask(
          taskMode: 'backfill',
          dayConcurrency: 2,
          targetDayKey: '2024-04-10',
        );

    expect(capturedArgs?['taskMode'], 'backfill');
    expect(capturedArgs?['dayConcurrency'], 2);
    expect(capturedArgs?['targetDayKey'], '2024-04-10');
    expect(status.targetDayKey, '2024-04-10');
  });

  test('startDynamicRebuildTask omits blank targetDayKey', () async {
    Map<dynamic, dynamic>? capturedArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_platformChannel, (MethodCall call) async {
          capturedArgs = call.arguments as Map<dynamic, dynamic>?;
          return _status(targetDayKey: '');
        });

    final DynamicRebuildTaskStatus status = await ScreenshotDatabase.instance
        .startDynamicRebuildTask(taskMode: 'backfill', targetDayKey: '   ');

    expect(capturedArgs?.containsKey('targetDayKey'), false);
    expect(status.targetDayKey, '');
  });
}
