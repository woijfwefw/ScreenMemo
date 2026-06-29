import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:screen_memo/core/constants/user_settings_keys.dart';
import 'package:screen_memo/data/database/screenshot_database.dart';
import 'package:screen_memo/data/platform/path_service.dart';
import 'package:screen_memo/data/settings/user_settings_service.dart';
import 'package:screen_memo/features/apps/application/app_selection_service.dart';
import 'package:screen_memo/features/permissions/application/permission_service.dart';

/// App 运行状态聚合服务。
///
/// 只记录结构化健康摘要，不保存用户内容、API Key、Prompt 或原始响应。
class AppHealthService {
  AppHealthService._();

  static final AppHealthService instance = AppHealthService._();

  final ScreenshotDatabase _db = ScreenshotDatabase.instance;

  static const int defaultBucketCount = 72;
  static const int maxBucketCount = 1440;
  static const Duration defaultRange = Duration(minutes: 72);
  static const Duration defaultSlotSize = Duration(minutes: 1);
  static const int baseBucketSizeMs =
      ScreenshotDatabaseHealth.appHealthBucketSizeMs;
  static const Duration autoCheckInterval = Duration(minutes: 1);

  Timer? _autoMonitorTimer;
  bool _autoMonitorRunning = false;
  int _lastAutoMonitorAt = 0;

  /// 启动自动健康检查。
  ///
  /// 说明：这是 Flutter 进程内的自动调度；应用进入后台但进程仍存活、
  /// 或被前台采集服务保活时会继续尝试运行。若系统杀死进程，则会在下次启动
  /// 或回到前台后补跑一次。
  void ensureAutoMonitorStarted({
    Duration interval = autoCheckInterval,
    bool runImmediately = true,
  }) {
    if (_autoMonitorTimer != null) return;
    final Duration safeInterval = interval < const Duration(minutes: 1)
        ? const Duration(minutes: 1)
        : interval;
    if (runImmediately) {
      unawaited(runAutoMonitorCheck(reason: 'startup'));
    }
    _autoMonitorTimer = Timer.periodic(safeInterval, (_) {
      unawaited(runAutoMonitorCheck(reason: 'periodic'));
    });
  }

  void stopAutoMonitor() {
    _autoMonitorTimer?.cancel();
    _autoMonitorTimer = null;
  }

  Future<void> runAutoMonitorCheckIfStale({
    Duration minInterval = const Duration(minutes: 1),
    String reason = 'resume',
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (_lastAutoMonitorAt > 0 &&
        now - _lastAutoMonitorAt < minInterval.inMilliseconds) {
      return;
    }
    await runAutoMonitorCheck(reason: reason);
  }

  Future<void> runAutoMonitorCheck({String reason = 'manual'}) async {
    if (_autoMonitorRunning) return;
    _autoMonitorRunning = true;
    _lastAutoMonitorAt = DateTime.now().millisecondsSinceEpoch;
    try {
      await refreshAndLoadSnapshot();
    } finally {
      _autoMonitorRunning = false;
    }
  }

  Future<AppHealthDashboardSnapshot> refreshAndLoadSnapshot({
    Duration range = defaultRange,
    Duration slotSize = defaultSlotSize,
  }) async {
    await _db.ensureAppHealthTables();
    await _refreshDatabaseHealth();
    await _refreshCaptureHealth();
    await _refreshStorageHealth();
    await _refreshBackgroundTaskHealth();
    return loadDashboardSnapshot(range: range, slotSize: slotSize);
  }

  Future<AppHealthDashboardSnapshot> loadDashboardSnapshot({
    Duration range = defaultRange,
    Duration slotSize = defaultSlotSize,
  }) async {
    try {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final window = _AppHealthDashboardWindow.create(
        now: now,
        requestedRange: range,
        requestedSlotSize: slotSize,
      );

      final currentRows = await _db.listAppHealthCurrent();
      final events = await _db.listAppHealthEvents(limit: 80);
      final bucketRows = await _db.listAppHealthBuckets(
        sinceMs: window.firstSlotStart,
        untilMs: window.currentSlotStart,
      );
      final Set<String> visibleComponents = AppHealthComponents.core.toSet();
      final visibleBucketRows = bucketRows
          .where(
            (row) =>
                visibleComponents.contains((row['component'] as String?) ?? ''),
          )
          .toList(growable: false);

      final Map<String, AppHealthCurrentStatus> byComponent =
          <String, AppHealthCurrentStatus>{};
      for (final row in currentRows) {
        final item = AppHealthCurrentStatus.fromDb(row);
        if (visibleComponents.contains(item.component)) {
          byComponent[item.component] = item;
        }
      }

      final List<AppHealthCurrentStatus> current = AppHealthComponents.core
          .map(
            (component) =>
                byComponent[component] ??
                AppHealthCurrentStatus.empty(component),
          )
          .toList(growable: false);

      final buckets = _buildBucketSlots(
        visibleBucketRows,
        firstSlotStart: window.firstSlotStart,
        slotCount: window.slotCount,
        slotSizeMs: window.slotSizeMs,
        now: now,
      );
      final Map<String, List<AppHealthBucketSlot>> componentBuckets =
          <String, List<AppHealthBucketSlot>>{};
      for (final String component in AppHealthComponents.core) {
        componentBuckets[component] = _buildBucketSlots(
          visibleBucketRows,
          firstSlotStart: window.firstSlotStart,
          slotCount: window.slotCount,
          slotSizeMs: window.slotSizeMs,
          now: now,
          component: component,
        );
      }

      final int unhealthyCount = current
          .where((item) => item.severity >= AppHealthSeverity.warning)
          .length;
      final int successTotal = current.fold<int>(
        0,
        (sum, item) => sum + item.successCount,
      );
      final int failureTotal = current.fold<int>(
        0,
        (sum, item) => sum + item.failureCount,
      );
      final int totalAttempts = successTotal + failureTotal;
      final double? successRate = totalAttempts == 0
          ? null
          : successTotal / totalAttempts;
      final int lastCheckedAt = current.fold<int>(
        0,
        (maxValue, item) =>
            item.lastCheckedAt > maxValue ? item.lastCheckedAt : maxValue,
      );

      return AppHealthDashboardSnapshot(
        generatedAt: now,
        range: window.range,
        requestedSlotSize: slotSize,
        slotSize: window.slotSize,
        slotSizeAdjusted: window.slotSizeAdjusted,
        current: current,
        buckets: buckets,
        componentBuckets: componentBuckets,
        events: events
            .where(
              (row) => visibleComponents.contains(
                (row['component'] as String?) ?? '',
              ),
            )
            .map((row) => AppHealthEvent.fromDb(row))
            .toList(growable: false),
        unhealthyCount: unhealthyCount,
        successRate: successRate,
        lastCheckedAt: lastCheckedAt,
      );
    } catch (e) {
      return AppHealthDashboardSnapshot.fallback(
        errorMessage: 'Failed to load app health: ${_clip(e.toString())}',
        range: range,
        slotSize: slotSize,
      );
    }
  }

  Future<void> recordCaptureServiceStarted({required int intervalSec}) {
    return _db.recordAppHealthStatus(
      component: AppHealthComponents.captureService,
      status: AppHealthStatusValues.ok,
      severity: AppHealthSeverity.none,
      countSuccess: true,
      eventType: 'capture_service_started',
      detail: <String, Object?>{'interval_sec': intervalSec},
    );
  }

  Future<void> recordCaptureServiceStopped() {
    return _db.recordAppHealthStatus(
      component: AppHealthComponents.captureService,
      status: AppHealthStatusValues.disabled,
      severity: AppHealthSeverity.none,
      eventType: 'capture_service_stopped',
    );
  }

  Future<void> recordCaptureFailure({
    required String errorType,
    required String errorMessage,
  }) {
    return _db.recordAppHealthStatus(
      component: AppHealthComponents.captureService,
      status: AppHealthStatusValues.failed,
      severity: AppHealthSeverity.critical,
      countFailure: true,
      eventType: 'capture_failure',
      errorType: errorType,
      errorMessage: errorMessage,
    );
  }

  Future<void> recordScreenshotSaved({
    required String packageName,
    required bool inserted,
  }) {
    return _db.recordAppHealthStatus(
      component: AppHealthComponents.captureService,
      status: AppHealthStatusValues.ok,
      severity: AppHealthSeverity.none,
      countSuccess: true,
      eventType: 'screenshot_saved',
      detail: <String, Object?>{
        'package_name': packageName,
        'inserted': inserted,
      },
    );
  }

  Future<void> recordScreenshotSaveFailure({
    required String errorType,
    required String errorMessage,
  }) {
    return _db.recordAppHealthStatus(
      component: AppHealthComponents.captureService,
      status: AppHealthStatusValues.failed,
      severity: AppHealthSeverity.critical,
      countFailure: true,
      eventType: 'screenshot_save_failed',
      errorType: errorType,
      errorMessage: errorMessage,
    );
  }

  Future<void> _refreshDatabaseHealth() async {
    try {
      final db = await _db.database;
      await db.rawQuery('SELECT 1');
      await _db.recordAppHealthStatus(
        component: AppHealthComponents.database,
        status: AppHealthStatusValues.ok,
        severity: AppHealthSeverity.none,
        countSuccess: true,
        eventType: 'database_check',
      );
    } catch (e) {
      await _db.recordAppHealthStatus(
        component: AppHealthComponents.database,
        status: AppHealthStatusValues.failed,
        severity: AppHealthSeverity.critical,
        countFailure: true,
        eventType: 'database_check_failed',
        errorType: 'db_check_failed',
        errorMessage: 'Database check failed: ${_clip(e.toString())}',
      );
    }
  }

  Future<void> _refreshCaptureHealth() async {
    try {
      final bool enabled = await AppSelectionService.instance
          .getScreenshotEnabled();
      final int interval = await AppSelectionService.instance
          .getScreenshotInterval();
      final selectedApps = await AppSelectionService.instance.getSelectedApps();
      final prefs = await SharedPreferences.getInstance();
      final bool rememberedRunning =
          prefs.getBool('screenshot_service_running') ?? false;
      bool nativeRunning = false;
      try {
        nativeRunning = await PermissionService.instance.isServiceRunning();
      } catch (_) {}

      if (!enabled) {
        await _db.recordAppHealthStatus(
          component: AppHealthComponents.captureService,
          status: AppHealthStatusValues.disabled,
          severity: AppHealthSeverity.none,
          eventType: 'capture_disabled',
          detail: <String, Object?>{
            'enabled': false,
            'selected_app_count': selectedApps.length,
          },
        );
        return;
      }

      if (selectedApps.isEmpty) {
        await _db.recordAppHealthStatus(
          component: AppHealthComponents.captureService,
          status: AppHealthStatusValues.degraded,
          severity: AppHealthSeverity.warning,
          countFailure: true,
          eventType: 'capture_no_selected_apps',
          errorType: 'capture_no_selected_apps',
          errorMessage: 'No selected apps for screenshot capture',
          detail: <String, Object?>{
            'enabled': true,
            'interval_sec': interval,
            'native_service_running': nativeRunning,
          },
        );
        return;
      }

      final bool healthy = nativeRunning;
      await _db.recordAppHealthStatus(
        component: AppHealthComponents.captureService,
        status: healthy
            ? AppHealthStatusValues.ok
            : AppHealthStatusValues.failed,
        severity: healthy ? AppHealthSeverity.none : AppHealthSeverity.critical,
        countSuccess: healthy,
        countFailure: !healthy,
        eventType: healthy ? 'capture_check' : 'capture_service_not_running',
        errorType: healthy ? null : 'capture_service_not_running',
        errorMessage: healthy
            ? null
            : 'Screenshot capture is enabled but service is not running',
        detail: <String, Object?>{
          'enabled': true,
          'remembered_running': rememberedRunning,
          'native_service_running': nativeRunning,
          'interval_sec': interval,
          'selected_app_count': selectedApps.length,
        },
      );
    } catch (e) {
      await _db.recordAppHealthStatus(
        component: AppHealthComponents.captureService,
        status: AppHealthStatusValues.failed,
        severity: AppHealthSeverity.critical,
        countFailure: true,
        eventType: 'capture_check_failed',
        errorType: 'capture_check_failed',
        errorMessage: 'Capture check failed: ${_clip(e.toString())}',
      );
    }
  }

  Future<void> _refreshStorageHealth() async {
    try {
      final Directory? dir = await PathService.getInternalAppDir(null);
      if (dir == null) {
        await _db.recordAppHealthStatus(
          component: AppHealthComponents.storage,
          status: AppHealthStatusValues.failed,
          severity: AppHealthSeverity.critical,
          countFailure: true,
          eventType: 'storage_dir_missing',
          errorType: 'storage_dir_missing',
          errorMessage: 'Internal storage directory is unavailable',
        );
        return;
      }

      final bool exists = await dir.exists();
      if (!exists) {
        await dir.create(recursive: true);
      }
      final File probe = File('${dir.path}/.app_health_probe');
      await probe.writeAsString('ok', flush: true);
      try {
        await probe.delete();
      } catch (_) {}
      await _db.recordAppHealthStatus(
        component: AppHealthComponents.storage,
        status: AppHealthStatusValues.ok,
        severity: AppHealthSeverity.none,
        countSuccess: true,
        eventType: 'storage_check',
        detail: <String, Object?>{'internal_dir_available': true},
      );
    } catch (e) {
      await _db.recordAppHealthStatus(
        component: AppHealthComponents.storage,
        status: AppHealthStatusValues.failed,
        severity: AppHealthSeverity.critical,
        countFailure: true,
        eventType: 'storage_check_failed',
        errorType: 'storage_check_failed',
        errorMessage: 'Storage check failed: ${_clip(e.toString())}',
      );
    }
  }

  Future<void> _refreshBackgroundTaskHealth() async {
    try {
      DynamicRebuildTaskStatus? dynamicStatus;
      try {
        dynamicStatus = await _db.getDynamicRebuildTaskStatus();
      } catch (_) {}
      final bool dailyEnabled = await UserSettingsService.instance.getBool(
        UserSettingKeys.dailyNotifyEnabled,
        defaultValue: true,
        legacyPrefKeys: const <String>['daily_notify_enabled'],
      );
      if (dynamicStatus != null && dynamicStatus.isActive) {
        await _db.recordAppHealthStatus(
          component: AppHealthComponents.backgroundTasks,
          status: AppHealthStatusValues.idle,
          severity: AppHealthSeverity.info,
          eventType: 'background_task_running',
          detail: <String, Object?>{
            'dynamic_rebuild_status': dynamicStatus.status,
            'dynamic_rebuild_progress': dynamicStatus.progressPercent,
            'daily_notify_enabled': dailyEnabled,
          },
        );
        return;
      }
      if (dynamicStatus != null &&
          (dynamicStatus.isFailed || dynamicStatus.isCompletedWithFailures)) {
        await _db.recordAppHealthStatus(
          component: AppHealthComponents.backgroundTasks,
          status: AppHealthStatusValues.degraded,
          severity: AppHealthSeverity.warning,
          countFailure: true,
          eventType: 'background_task_failed',
          errorType: 'background_task_failed',
          errorMessage:
              dynamicStatus.lastError ??
              'Background task completed with failures',
          detail: <String, Object?>{
            'dynamic_rebuild_status': dynamicStatus.status,
            'failed_segments': dynamicStatus.failedSegments,
            'failed_days': dynamicStatus.failedDays,
            'daily_notify_enabled': dailyEnabled,
          },
        );
        return;
      }
      await _db.recordAppHealthStatus(
        component: AppHealthComponents.backgroundTasks,
        status: AppHealthStatusValues.ok,
        severity: AppHealthSeverity.none,
        countSuccess: true,
        eventType: 'background_task_check',
        detail: <String, Object?>{
          'dynamic_rebuild_status': dynamicStatus?.status ?? 'idle',
          'daily_notify_enabled': dailyEnabled,
        },
      );
    } catch (e) {
      await _db.recordAppHealthStatus(
        component: AppHealthComponents.backgroundTasks,
        status: AppHealthStatusValues.degraded,
        severity: AppHealthSeverity.warning,
        countFailure: true,
        eventType: 'background_task_check_failed',
        errorType: 'background_task_check_failed',
        errorMessage: 'Background task check failed: ${_clip(e.toString())}',
      );
    }
  }

  List<AppHealthBucketSlot> _buildBucketSlots(
    List<Map<String, dynamic>> rows, {
    required int firstSlotStart,
    required int slotCount,
    required int slotSizeMs,
    required int now,
    String? component,
  }) {
    final Map<int, List<Map<String, dynamic>>> byStart =
        <int, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      if (component != null && row['component'] != component) continue;
      final int start = _asInt(row['bucket_start']);
      if (start <= 0) continue;
      final int slotStart = start - (start % slotSizeMs);
      if (slotStart < firstSlotStart) continue;
      byStart.putIfAbsent(slotStart, () => <Map<String, dynamic>>[]).add(row);
    }

    return List<AppHealthBucketSlot>.generate(slotCount, (int index) {
      final int start = firstSlotStart + index * slotSizeMs;
      final List<Map<String, dynamic>> items =
          byStart[start] ?? const <Map<String, dynamic>>[];
      if (items.isEmpty) {
        return AppHealthBucketSlot(
          bucketStart: start,
          bucketEnd: start + slotSizeMs,
          status: AppHealthStatusValues.noData,
          severity: AppHealthSeverity.none,
          checkedCount: 0,
          successCount: 0,
          failureCount: 0,
        );
      }
      int severity = AppHealthSeverity.none;
      int checked = 0;
      int success = 0;
      int failure = 0;
      String status = AppHealthStatusValues.noData;
      for (final item in items) {
        final int itemSeverity = _asInt(item['severity']);
        if (itemSeverity >= severity) {
          severity = itemSeverity;
          status = (item['status'] as String?) ?? status;
        }
        checked += _asInt(item['checked_count']);
        success += _asInt(item['success_count']);
        failure += _asInt(item['failure_count']);
      }
      if (severity <= AppHealthSeverity.info && success > 0) {
        status = AppHealthStatusValues.ok;
      } else if (severity >= AppHealthSeverity.critical) {
        status = AppHealthStatusValues.failed;
      } else if (severity >= AppHealthSeverity.warning) {
        status = AppHealthStatusValues.degraded;
      }
      return AppHealthBucketSlot(
        bucketStart: start,
        bucketEnd: start + slotSizeMs,
        status: status,
        severity: severity,
        checkedCount: checked,
        successCount: success,
        failureCount: failure,
      );
    }, growable: false);
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _clip(String value, {int max = 180}) {
    final String text = value.trim();
    if (text.length <= max) return text;
    return text.substring(0, max);
  }
}

class _AppHealthDashboardWindow {
  const _AppHealthDashboardWindow({
    required this.range,
    required this.slotSize,
    required this.slotSizeAdjusted,
    required this.currentSlotStart,
    required this.firstSlotStart,
    required this.slotCount,
  });

  factory _AppHealthDashboardWindow.create({
    required int now,
    required Duration requestedRange,
    required Duration requestedSlotSize,
  }) {
    final int baseMs = AppHealthService.baseBucketSizeMs;
    final int minRangeMs = AppHealthService.defaultSlotSize.inMilliseconds;
    final int requestedRangeMs = requestedRange.inMilliseconds <= 0
        ? AppHealthService.defaultRange.inMilliseconds
        : requestedRange.inMilliseconds;
    final int rangeMs = math.max(minRangeMs, requestedRangeMs);
    int slotMs = requestedSlotSize.inMilliseconds <= 0
        ? AppHealthService.defaultSlotSize.inMilliseconds
        : requestedSlotSize.inMilliseconds;
    slotMs = _roundUpToBase(slotMs, baseMs);

    final int requestedSlotMs = slotMs;
    final int requestedSlotCount = (rangeMs / slotMs)
        .ceil()
        .clamp(1, 1 << 30)
        .toInt();
    if (requestedSlotCount > AppHealthService.maxBucketCount) {
      slotMs = _roundUpToBase(
        (rangeMs / AppHealthService.maxBucketCount).ceil(),
        baseMs,
      );
    }

    final int slotCount = (rangeMs / slotMs)
        .ceil()
        .clamp(1, AppHealthService.maxBucketCount)
        .toInt();
    final int currentSlotStart = now - (now % slotMs);
    final int firstSlotStart = currentSlotStart - (slotCount - 1) * slotMs;
    return _AppHealthDashboardWindow(
      range: Duration(milliseconds: rangeMs),
      slotSize: Duration(milliseconds: slotMs),
      slotSizeAdjusted: slotMs != requestedSlotMs,
      currentSlotStart: currentSlotStart,
      firstSlotStart: firstSlotStart,
      slotCount: slotCount,
    );
  }

  final Duration range;
  final Duration slotSize;
  final bool slotSizeAdjusted;
  final int currentSlotStart;
  final int firstSlotStart;
  final int slotCount;

  int get slotSizeMs => slotSize.inMilliseconds;

  static int _roundUpToBase(int valueMs, int baseMs) {
    final int safeBase = baseMs <= 0 ? 60 * 1000 : baseMs;
    final int safeValue = math.max(safeBase, valueMs);
    return ((safeValue + safeBase - 1) ~/ safeBase) * safeBase;
  }
}

class AppHealthDurationLabels {
  AppHealthDurationLabels._();

  static String compact(Duration duration) {
    final int minutes = (duration.inMilliseconds / 60000)
        .round()
        .clamp(1, 1 << 30)
        .toInt();
    if (minutes % (60 * 24) == 0) return '${minutes ~/ (60 * 24)}天';
    if (minutes % 60 == 0) return '${minutes ~/ 60}小时';
    return '$minutes分钟';
  }
}

class AppHealthDashboardSnapshot {
  const AppHealthDashboardSnapshot({
    required this.generatedAt,
    required this.range,
    required this.requestedSlotSize,
    required this.slotSize,
    required this.slotSizeAdjusted,
    required this.current,
    required this.buckets,
    required this.componentBuckets,
    required this.events,
    required this.unhealthyCount,
    required this.successRate,
    required this.lastCheckedAt,
  });

  factory AppHealthDashboardSnapshot.fallback({
    required String errorMessage,
    Duration range = AppHealthService.defaultRange,
    Duration slotSize = AppHealthService.defaultSlotSize,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final window = _AppHealthDashboardWindow.create(
      now: now,
      requestedRange: range,
      requestedSlotSize: slotSize,
    );
    List<AppHealthBucketSlot> emptySlots() {
      return List<AppHealthBucketSlot>.generate(window.slotCount, (int index) {
        final int start = window.firstSlotStart + index * window.slotSizeMs;
        return AppHealthBucketSlot(
          bucketStart: start,
          bucketEnd: start + window.slotSizeMs,
          status: AppHealthStatusValues.noData,
          severity: AppHealthSeverity.none,
          checkedCount: 0,
          successCount: 0,
          failureCount: 0,
        );
      }, growable: false);
    }

    return AppHealthDashboardSnapshot(
      generatedAt: now,
      range: window.range,
      requestedSlotSize: slotSize,
      slotSize: window.slotSize,
      slotSizeAdjusted: window.slotSizeAdjusted,
      current: AppHealthComponents.core
          .map(AppHealthCurrentStatus.empty)
          .toList(growable: false),
      buckets: emptySlots(),
      componentBuckets: <String, List<AppHealthBucketSlot>>{
        for (final component in AppHealthComponents.core)
          component: emptySlots(),
      },
      events: <AppHealthEvent>[
        AppHealthEvent(
          component: AppHealthComponents.database,
          status: AppHealthStatusValues.failed,
          severity: AppHealthSeverity.critical,
          eventType: 'snapshot_load_failed',
          errorType: 'snapshot_load_failed',
          errorMessage: errorMessage,
          createdAt: now,
        ),
      ],
      unhealthyCount: 1,
      successRate: null,
      lastCheckedAt: 0,
    );
  }

  final int generatedAt;
  final Duration range;
  final Duration requestedSlotSize;
  final Duration slotSize;
  final bool slotSizeAdjusted;
  final List<AppHealthCurrentStatus> current;
  final List<AppHealthBucketSlot> buckets;
  final Map<String, List<AppHealthBucketSlot>> componentBuckets;
  final List<AppHealthEvent> events;
  final int unhealthyCount;
  final double? successRate;
  final int lastCheckedAt;

  bool get hasAnyData => current.any((item) => item.lastCheckedAt > 0);

  int get slotCount => buckets.length;

  List<AppHealthBucketSlot> bucketsForComponent(String component) =>
      componentBuckets[component] ?? const <AppHealthBucketSlot>[];

  String get rangeLabel => AppHealthDurationLabels.compact(range);

  String get slotLabel => AppHealthDurationLabels.compact(slotSize);

  int get overallSeverity {
    if (!hasAnyData) return AppHealthSeverity.none;
    return current.fold<int>(
      AppHealthSeverity.none,
      (maxValue, item) => item.severity > maxValue ? item.severity : maxValue,
    );
  }

  String get overallStatus {
    if (!hasAnyData) return AppHealthStatusValues.noData;
    if (overallSeverity >= AppHealthSeverity.critical) {
      return AppHealthStatusValues.failed;
    }
    if (overallSeverity >= AppHealthSeverity.warning) {
      return AppHealthStatusValues.degraded;
    }
    return AppHealthStatusValues.ok;
  }

  String get overallLabel {
    switch (overallStatus) {
      case AppHealthStatusValues.failed:
        return '需要处理';
      case AppHealthStatusValues.degraded:
        return '部分异常';
      case AppHealthStatusValues.ok:
        return '运行正常';
      default:
        return '暂无数据';
    }
  }
}

class AppHealthCurrentStatus {
  const AppHealthCurrentStatus({
    required this.component,
    required this.status,
    required this.severity,
    required this.lastSuccessAt,
    required this.lastFailureAt,
    required this.lastCheckedAt,
    required this.successCount,
    required this.failureCount,
    required this.consecutiveFailures,
    required this.lastErrorType,
    required this.lastErrorMessage,
    required this.detail,
  });

  factory AppHealthCurrentStatus.empty(String component) {
    return AppHealthCurrentStatus(
      component: component,
      status: AppHealthStatusValues.noData,
      severity: AppHealthSeverity.none,
      lastSuccessAt: 0,
      lastFailureAt: 0,
      lastCheckedAt: 0,
      successCount: 0,
      failureCount: 0,
      consecutiveFailures: 0,
      lastErrorType: null,
      lastErrorMessage: null,
      detail: const <String, Object?>{},
    );
  }

  factory AppHealthCurrentStatus.fromDb(Map<String, dynamic> row) {
    return AppHealthCurrentStatus(
      component: (row['component'] as String?) ?? '',
      status: (row['status'] as String?) ?? AppHealthStatusValues.noData,
      severity: AppHealthService._asInt(row['severity']),
      lastSuccessAt: AppHealthService._asInt(row['last_success_at']),
      lastFailureAt: AppHealthService._asInt(row['last_failure_at']),
      lastCheckedAt: AppHealthService._asInt(row['last_checked_at']),
      successCount: AppHealthService._asInt(row['success_count']),
      failureCount: AppHealthService._asInt(row['failure_count']),
      consecutiveFailures: AppHealthService._asInt(row['consecutive_failures']),
      lastErrorType: (row['last_error_type'] as String?)?.trim(),
      lastErrorMessage: (row['last_error_message'] as String?)?.trim(),
      detail: _decodeDetail(row['detail_json']),
    );
  }

  final String component;
  final String status;
  final int severity;
  final int lastSuccessAt;
  final int lastFailureAt;
  final int lastCheckedAt;
  final int successCount;
  final int failureCount;
  final int consecutiveFailures;
  final String? lastErrorType;
  final String? lastErrorMessage;
  final Map<String, Object?> detail;

  int get totalAttempts => successCount + failureCount;

  double? get successRate =>
      totalAttempts == 0 ? null : successCount / totalAttempts;

  String get componentLabel {
    switch (component) {
      case AppHealthComponents.captureService:
        return '采集服务';
      case AppHealthComponents.database:
        return '数据库';
      case AppHealthComponents.storage:
        return '存储';
      case AppHealthComponents.backgroundTasks:
        return '后台任务';
      default:
        return component;
    }
  }

  String get statusLabel {
    switch (status) {
      case AppHealthStatusValues.ok:
        return '正常';
      case AppHealthStatusValues.degraded:
        return '降级';
      case AppHealthStatusValues.failed:
        return '失败';
      case AppHealthStatusValues.idle:
        return '等待中';
      case AppHealthStatusValues.disabled:
        return '已关闭';
      default:
        return '暂无数据';
    }
  }

  static Map<String, Object?> _decodeDetail(Object? value) {
    final String text = (value as String?)?.trim() ?? '';
    if (text.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return Map<String, Object?>.from(decoded);
      }
    } catch (_) {}
    return const <String, Object?>{};
  }
}

class AppHealthBucketSlot {
  const AppHealthBucketSlot({
    required this.bucketStart,
    required this.bucketEnd,
    required this.status,
    required this.severity,
    required this.checkedCount,
    required this.successCount,
    required this.failureCount,
  });

  final int bucketStart;
  final int bucketEnd;
  final String status;
  final int severity;
  final int checkedCount;
  final int successCount;
  final int failureCount;
}

class AppHealthEvent {
  const AppHealthEvent({
    required this.component,
    required this.status,
    required this.severity,
    required this.eventType,
    required this.errorType,
    required this.errorMessage,
    required this.createdAt,
  });

  factory AppHealthEvent.fromDb(Map<String, dynamic> row) {
    return AppHealthEvent(
      component: (row['component'] as String?) ?? '',
      status: (row['status'] as String?) ?? AppHealthStatusValues.noData,
      severity: AppHealthService._asInt(row['severity']),
      eventType: (row['event_type'] as String?) ?? 'status_changed',
      errorType: (row['error_type'] as String?)?.trim(),
      errorMessage: (row['error_message'] as String?)?.trim(),
      createdAt: AppHealthService._asInt(row['created_at']),
    );
  }

  final String component;
  final String status;
  final int severity;
  final String eventType;
  final String? errorType;
  final String? errorMessage;
  final int createdAt;

  String get componentLabel =>
      AppHealthCurrentStatus.empty(component).componentLabel;
}
