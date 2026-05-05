part of 'screenshot_database.dart';

/// App 健康状态取值，统一用于数据库与 UI。
class AppHealthStatusValues {
  AppHealthStatusValues._();

  static const String ok = 'ok';
  static const String degraded = 'degraded';
  static const String failed = 'failed';
  static const String idle = 'idle';
  static const String disabled = 'disabled';
  static const String noData = 'no_data';
}

/// App 健康状态严重级别。
///
/// 说明：状态颜色不只依赖 severity，例如 ok 仍显示绿色。
class AppHealthSeverity {
  AppHealthSeverity._();

  static const int none = 0;
  static const int info = 1;
  static const int warning = 2;
  static const int critical = 3;
}

/// App 运行状态组件 ID。
class AppHealthComponents {
  AppHealthComponents._();

  static const String captureService = 'capture_service';
  static const String permissions = 'permissions';
  static const String database = 'database';
  static const String storage = 'storage';
  static const String aiProcessing = 'ai_processing';
  static const String backgroundTasks = 'background_tasks';

  static const List<String> core = <String>[
    captureService,
    permissions,
    database,
    storage,
    aiProcessing,
    backgroundTasks,
  ];
}

// App 运行状态数据库扩展：只保存结构化摘要，不保存截图、Prompt、Key 或原始响应。
extension ScreenshotDatabaseHealth on ScreenshotDatabase {
  /// 健康状态基础时间桶：每 1 分钟聚合一次。
  ///
  /// UI 可以在读取时继续按 5 分钟、30 分钟、1 小时等粒度二次聚合；
  /// 底层始终保留 1 分钟明细，便于用户回看更长时间线。
  static const int appHealthBucketSizeMs = 60 * 1000;

  Future<void> _createAppHealthTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_health_current (
        component TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        severity INTEGER NOT NULL DEFAULT 0,
        last_success_at INTEGER,
        last_failure_at INTEGER,
        last_checked_at INTEGER NOT NULL,
        success_count INTEGER NOT NULL DEFAULT 0,
        failure_count INTEGER NOT NULL DEFAULT 0,
        consecutive_failures INTEGER NOT NULL DEFAULT 0,
        last_error_type TEXT,
        last_error_message TEXT,
        detail_json TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_health_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        component TEXT NOT NULL,
        status TEXT NOT NULL,
        severity INTEGER NOT NULL DEFAULT 0,
        event_type TEXT NOT NULL,
        error_type TEXT,
        error_message TEXT,
        detail_json TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_app_health_events_component_time ON app_health_events(component, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_app_health_events_time ON app_health_events(created_at DESC)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_health_buckets (
        component TEXT NOT NULL,
        bucket_start INTEGER NOT NULL,
        status TEXT NOT NULL,
        severity INTEGER NOT NULL DEFAULT 0,
        checked_count INTEGER NOT NULL DEFAULT 0,
        success_count INTEGER NOT NULL DEFAULT 0,
        failure_count INTEGER NOT NULL DEFAULT 0,
        last_error_type TEXT,
        last_error_message TEXT,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (component, bucket_start)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_app_health_buckets_time ON app_health_buckets(bucket_start DESC)',
    );
  }

  Future<void> ensureAppHealthTables() async {
    final db = await database;
    await _createAppHealthTables(db);
  }

  Future<void> recordAppHealthStatus({
    required String component,
    required String status,
    required int severity,
    bool countSuccess = false,
    bool countFailure = false,
    String? eventType,
    String? errorType,
    String? errorMessage,
    Map<String, Object?>? detail,
    int? checkedAt,
  }) async {
    final String normalizedComponent = _normalizeAppHealthToken(component);
    if (normalizedComponent.isEmpty) return;
    final String normalizedStatus = _normalizeAppHealthStatus(status);
    final int safeSeverity = severity.clamp(
      AppHealthSeverity.none,
      AppHealthSeverity.critical,
    );
    final int now = checkedAt ?? DateTime.now().millisecondsSinceEpoch;
    final String? clippedErrorType = _clipAppHealthText(errorType, max: 80);
    final String? clippedErrorMessage = _clipAppHealthText(
      errorMessage,
      max: 240,
    );
    final String? detailJson = _encodeAppHealthDetail(detail);

    try {
      final db = await database;
      await _createAppHealthTables(db);
      await db.transaction((txn) async {
        final List<Map<String, Object?>> rows = await txn.query(
          'app_health_current',
          where: 'component = ?',
          whereArgs: <Object?>[normalizedComponent],
          limit: 1,
        );
        final Map<String, Object?>? before = rows.isEmpty ? null : rows.first;
        final int previousSuccess = _healthInt(before?['success_count']);
        final int previousFailure = _healthInt(before?['failure_count']);
        final int previousConsecutive = _healthInt(
          before?['consecutive_failures'],
        );
        final int successCount = previousSuccess + (countSuccess ? 1 : 0);
        final int failureCount = previousFailure + (countFailure ? 1 : 0);
        final int consecutiveFailures = countFailure
            ? previousConsecutive + 1
            : (countSuccess ? 0 : previousConsecutive);

        final Map<String, Object?> data = <String, Object?>{
          'component': normalizedComponent,
          'status': normalizedStatus,
          'severity': safeSeverity,
          'last_success_at': countSuccess ? now : before?['last_success_at'],
          'last_failure_at': countFailure ? now : before?['last_failure_at'],
          'last_checked_at': now,
          'success_count': successCount,
          'failure_count': failureCount,
          'consecutive_failures': consecutiveFailures,
          'last_error_type': countSuccess ? null : clippedErrorType,
          'last_error_message': countSuccess ? null : clippedErrorMessage,
          'detail_json': detailJson,
          'updated_at': now,
        };

        if (before == null) {
          await txn.insert('app_health_current', data);
        } else {
          await txn.update(
            'app_health_current',
            data..remove('component'),
            where: 'component = ?',
            whereArgs: <Object?>[normalizedComponent],
          );
        }

        await _upsertAppHealthBucket(
          txn,
          component: normalizedComponent,
          status: normalizedStatus,
          severity: safeSeverity,
          countSuccess: countSuccess,
          countFailure: countFailure,
          errorType: clippedErrorType,
          errorMessage: clippedErrorMessage,
          now: now,
        );

        final int previousSeverity = _healthInt(before?['severity']);
        final String previousStatus = (before?['status'] as String?) ?? '';
        final bool changed =
            before == null ||
            previousStatus != normalizedStatus ||
            previousSeverity != safeSeverity;
        final String previousErrorType =
            (before?['last_error_type'] as String?) ?? '';
        final bool failureChanged =
            countFailure &&
            (changed || previousErrorType != (clippedErrorType ?? ''));
        final bool shouldCreateEvent =
            failureChanged ||
            (changed && safeSeverity >= AppHealthSeverity.warning);
        if (shouldCreateEvent) {
          await txn.insert('app_health_events', <String, Object?>{
            'component': normalizedComponent,
            'status': normalizedStatus,
            'severity': safeSeverity,
            'event_type':
                eventType ??
                (countFailure
                    ? 'failure'
                    : (countSuccess ? 'success' : 'status_changed')),
            'error_type': clippedErrorType,
            'error_message': clippedErrorMessage,
            'detail_json': detailJson,
            'created_at': now,
          });
        }
      });
    } catch (_) {
      // 健康状态本身不能阻断业务链路。
    }
  }

  Future<List<Map<String, dynamic>>> listAppHealthCurrent() async {
    try {
      final db = await database;
      await _createAppHealthTables(db);
      final rows = await db.query('app_health_current');
      return rows.map((row) => Map<String, dynamic>.from(row)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> listAppHealthEvents({
    int limit = 50,
    String? component,
  }) async {
    try {
      final db = await database;
      await _createAppHealthTables(db);
      final String? normalizedComponent =
          component == null || component.trim().isEmpty
          ? null
          : _normalizeAppHealthToken(component);
      final rows = await db.query(
        'app_health_events',
        where: normalizedComponent == null ? null : 'component = ?',
        whereArgs: normalizedComponent == null
            ? null
            : <Object?>[normalizedComponent],
        orderBy: 'created_at DESC, id DESC',
        limit: limit.clamp(1, 200),
      );
      return rows.map((row) => Map<String, dynamic>.from(row)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> listAppHealthBuckets({
    required int sinceMs,
    int? untilMs,
  }) async {
    try {
      final db = await database;
      await _createAppHealthTables(db);
      final bool hasUntil = untilMs != null && untilMs > sinceMs;
      final rows = await db.query(
        'app_health_buckets',
        where: hasUntil
            ? 'bucket_start >= ? AND bucket_start <= ?'
            : 'bucket_start >= ?',
        whereArgs: hasUntil ? <Object?>[sinceMs, untilMs] : <Object?>[sinceMs],
        orderBy: 'bucket_start ASC',
      );
      return rows.map((row) => Map<String, dynamic>.from(row)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// 手动维护入口：默认不自动清理健康历史。
  ///
  /// App 运行状态是故障追踪依据，自动检查不会调用该方法；保留方法仅供未来
  /// “用户明确释放空间 / 导出归档后清理”场景使用。
  Future<void> cleanupAppHealthHistory({
    int eventsRetentionDays = 30,
    int bucketsRetentionDays = 60,
  }) async {
    try {
      final db = await database;
      await _createAppHealthTables(db);
      final int now = DateTime.now().millisecondsSinceEpoch;
      final int eventCutoff =
          now - eventsRetentionDays.clamp(1, 365) * 24 * 60 * 60 * 1000;
      final int bucketCutoff =
          now - bucketsRetentionDays.clamp(1, 365) * 24 * 60 * 60 * 1000;
      await db.delete(
        'app_health_events',
        where: 'created_at < ?',
        whereArgs: <Object?>[eventCutoff],
      );
      await db.delete(
        'app_health_buckets',
        where: 'bucket_start < ?',
        whereArgs: <Object?>[bucketCutoff],
      );
    } catch (_) {}
  }

  Future<void> _upsertAppHealthBucket(
    DatabaseExecutor txn, {
    required String component,
    required String status,
    required int severity,
    required bool countSuccess,
    required bool countFailure,
    required String? errorType,
    required String? errorMessage,
    required int now,
  }) async {
    final int bucketStart = now - (now % appHealthBucketSizeMs);
    final List<Map<String, Object?>> rows = await txn.query(
      'app_health_buckets',
      where: 'component = ? AND bucket_start = ?',
      whereArgs: <Object?>[component, bucketStart],
      limit: 1,
    );
    if (rows.isEmpty) {
      await txn.insert('app_health_buckets', <String, Object?>{
        'component': component,
        'bucket_start': bucketStart,
        'status': status,
        'severity': severity,
        'checked_count': 1,
        'success_count': countSuccess ? 1 : 0,
        'failure_count': countFailure ? 1 : 0,
        'last_error_type': errorType,
        'last_error_message': errorMessage,
        'updated_at': now,
      });
      return;
    }

    final Map<String, Object?> before = rows.first;
    final int previousSeverity = _healthInt(before['severity']);
    final bool newStatusWins = severity >= previousSeverity;
    await txn.update(
      'app_health_buckets',
      <String, Object?>{
        'status': newStatusWins ? status : before['status'],
        'severity': math.max(previousSeverity, severity),
        'checked_count': _healthInt(before['checked_count']) + 1,
        'success_count':
            _healthInt(before['success_count']) + (countSuccess ? 1 : 0),
        'failure_count':
            _healthInt(before['failure_count']) + (countFailure ? 1 : 0),
        'last_error_type': errorType ?? before['last_error_type'],
        'last_error_message': errorMessage ?? before['last_error_message'],
        'updated_at': now,
      },
      where: 'component = ? AND bucket_start = ?',
      whereArgs: <Object?>[component, bucketStart],
    );
  }

  String _normalizeAppHealthToken(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_\-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
  }

  String _normalizeAppHealthStatus(String value) {
    final String normalized = _normalizeAppHealthToken(value);
    switch (normalized) {
      case AppHealthStatusValues.ok:
      case AppHealthStatusValues.degraded:
      case AppHealthStatusValues.failed:
      case AppHealthStatusValues.idle:
      case AppHealthStatusValues.disabled:
      case AppHealthStatusValues.noData:
        return normalized;
      default:
        return AppHealthStatusValues.noData;
    }
  }

  int _healthInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String? _clipAppHealthText(String? value, {required int max}) {
    final String text = (value ?? '').trim();
    if (text.isEmpty) return null;
    return text.length <= max ? text : text.substring(0, max);
  }

  String? _encodeAppHealthDetail(Map<String, Object?>? detail) {
    if (detail == null || detail.isEmpty) return null;
    final Map<String, Object?> safe = <String, Object?>{};
    detail.forEach((String key, Object? value) {
      final String cleanKey = _normalizeAppHealthToken(key);
      if (cleanKey.isEmpty) return;
      if (value == null || value is num || value is bool) {
        safe[cleanKey] = value;
      } else if (value is Iterable) {
        safe[cleanKey] = value
            .map((Object? item) => _clipAppHealthText('$item', max: 80))
            .whereType<String>()
            .toList(growable: false);
      } else {
        safe[cleanKey] = _clipAppHealthText('$value', max: 160);
      }
    });
    if (safe.isEmpty) return null;
    return jsonEncode(safe);
  }
}
