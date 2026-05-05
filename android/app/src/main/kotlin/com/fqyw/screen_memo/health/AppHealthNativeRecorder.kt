package com.fqyw.screen_memo.health

import android.Manifest
import android.app.AlarmManager
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import com.fqyw.screen_memo.capture.ScreenCaptureAccessibilityService
import com.fqyw.screen_memo.database.ScreenshotDatabaseHelper
import com.fqyw.screen_memo.dynamic.DynamicRebuildService
import com.fqyw.screen_memo.importing.ImportOcrRepairService
import com.fqyw.screen_memo.service.ServiceDebugHelper
import com.fqyw.screen_memo.service.ServiceStateManager
import com.fqyw.screen_memo.settings.LegacySettingKeysNative
import com.fqyw.screen_memo.settings.UserSettingsKeysNative
import com.fqyw.screen_memo.settings.UserSettingsStorage
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale
import kotlin.math.max

/**
 * 原生健康状态记录器。
 *
 * 只写入结构化摘要，不写截图内容、Prompt、API Key、AI 原始响应或完整堆栈。
 */
object AppHealthNativeRecorder {
    private const val BASE_BUCKET_MS = 60_000L

    private const val STATUS_OK = "ok"
    private const val STATUS_DEGRADED = "degraded"
    private const val STATUS_FAILED = "failed"
    private const val STATUS_IDLE = "idle"
    private const val STATUS_DISABLED = "disabled"
    private const val STATUS_NO_DATA = "no_data"

    private const val SEVERITY_NONE = 0
    private const val SEVERITY_INFO = 1
    private const val SEVERITY_WARNING = 2
    private const val SEVERITY_CRITICAL = 3

    private const val COMPONENT_CAPTURE = "capture_service"
    private const val COMPONENT_PERMISSIONS = "permissions"
    private const val COMPONENT_DATABASE = "database"
    private const val COMPONENT_STORAGE = "storage"
    private const val COMPONENT_AI = "ai_processing"
    private const val COMPONENT_BACKGROUND = "background_tasks"

    fun recordSnapshot(context: Context, source: String = "native") {
        val appContext = context.applicationContext ?: context
        recordDatabaseHealth(appContext, source)
        recordPermissionHealth(appContext, source)
        recordCaptureHealth(appContext, source)
        recordStorageHealth(appContext, source)
        recordBackgroundTaskHealth(appContext, source)
        seedAiHealthIfMissing(appContext, source)
    }

    fun recordStatus(
        context: Context,
        component: String,
        status: String,
        severity: Int,
        countSuccess: Boolean = false,
        countFailure: Boolean = false,
        eventType: String? = null,
        errorType: String? = null,
        errorMessage: String? = null,
        detail: Map<String, Any?>? = null,
        checkedAt: Long = System.currentTimeMillis()
    ) {
        val normalizedComponent = normalizeToken(component)
        if (normalizedComponent.isBlank()) return
        val normalizedStatus = normalizeStatus(status)
        val safeSeverity = severity.coerceIn(SEVERITY_NONE, SEVERITY_CRITICAL)
        val clippedErrorType = clip(errorType, 80)
        val clippedErrorMessage = clip(errorMessage, 240)
        val detailJson = encodeDetail(detail)

        var db: SQLiteDatabase? = null
        try {
            val path = ScreenshotDatabaseHelper.resolveMasterDbPath(context) ?: return
            db = SQLiteDatabase.openDatabase(
                path,
                null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY
            )
            ensureTables(db)
            db.beginTransaction()

            val before = queryCurrent(db, normalizedComponent)
            val previousSuccess = asLong(before?.get("success_count"))
            val previousFailure = asLong(before?.get("failure_count"))
            val previousConsecutive = asLong(before?.get("consecutive_failures"))
            val successCount = previousSuccess + if (countSuccess) 1L else 0L
            val failureCount = previousFailure + if (countFailure) 1L else 0L
            val consecutiveFailures = when {
                countFailure -> previousConsecutive + 1L
                countSuccess -> 0L
                else -> previousConsecutive
            }

            val lastSuccessAt = if (countSuccess) checkedAt else before?.get("last_success_at")
            val lastFailureAt = if (countFailure) checkedAt else before?.get("last_failure_at")
            db.execSQL(
                """
                INSERT OR REPLACE INTO app_health_current(
                  component, status, severity, last_success_at, last_failure_at,
                  last_checked_at, success_count, failure_count, consecutive_failures,
                  last_error_type, last_error_message, detail_json, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf<Any?>(
                    normalizedComponent,
                    normalizedStatus,
                    safeSeverity,
                    lastSuccessAt,
                    lastFailureAt,
                    checkedAt,
                    successCount,
                    failureCount,
                    consecutiveFailures,
                    if (countSuccess) null else clippedErrorType,
                    if (countSuccess) null else clippedErrorMessage,
                    detailJson,
                    checkedAt
                )
            )

            upsertBucket(
                db,
                normalizedComponent,
                normalizedStatus,
                safeSeverity,
                countSuccess,
                countFailure,
                clippedErrorType,
                clippedErrorMessage,
                checkedAt
            )

            val previousSeverity = asLong(before?.get("severity")).toInt()
            val previousStatus = before?.get("status")?.toString().orEmpty()
            val changed = before == null || previousStatus != normalizedStatus || previousSeverity != safeSeverity
            val previousErrorType = before?.get("last_error_type")?.toString().orEmpty()
            val failureChanged = countFailure && (changed || previousErrorType != clippedErrorType.orEmpty())
            val shouldCreateEvent = failureChanged || (changed && safeSeverity >= SEVERITY_WARNING)
            if (shouldCreateEvent) {
                db.execSQL(
                    """
                    INSERT INTO app_health_events(
                      component, status, severity, event_type, error_type,
                      error_message, detail_json, created_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    """.trimIndent(),
                    arrayOf<Any?>(
                        normalizedComponent,
                        normalizedStatus,
                        safeSeverity,
                        eventType
                            ?: if (countFailure) "failure" else if (countSuccess) "success" else "status_changed",
                        clippedErrorType,
                        clippedErrorMessage,
                        detailJson,
                        checkedAt,
                    )
                )
            }

            db.setTransactionSuccessful()
        } catch (_: Throwable) {
            // 健康状态不能阻断主业务或系统广播。
        } finally {
            try { db?.endTransaction() } catch (_: Throwable) {}
            try { db?.close() } catch (_: Throwable) {}
        }
    }

    private fun recordDatabaseHealth(context: Context, source: String) {
        var db: SQLiteDatabase? = null
        try {
            val path = ScreenshotDatabaseHelper.resolveMasterDbPath(context) ?: throw IllegalStateException("db_path_missing")
            db = SQLiteDatabase.openDatabase(
                path,
                null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY
            )
            ensureTables(db)
            db.rawQuery("SELECT 1", emptyArray()).use { cursor -> cursor.moveToFirst() }
            recordStatus(
                context,
                component = COMPONENT_DATABASE,
                status = STATUS_OK,
                severity = SEVERITY_NONE,
                countSuccess = true,
                eventType = "native_database_check",
                detail = mapOf("source" to source)
            )
        } catch (t: Throwable) {
            recordStatus(
                context,
                component = COMPONENT_DATABASE,
                status = STATUS_FAILED,
                severity = SEVERITY_CRITICAL,
                countFailure = true,
                eventType = "native_database_check_failed",
                errorType = "db_check_failed",
                errorMessage = "Database check failed: ${clip(t.message, 160) ?: t.javaClass.simpleName}",
                detail = mapOf("source" to source)
            )
        } finally {
            try { db?.close() } catch (_: Throwable) {}
        }
    }

    private fun recordPermissionHealth(context: Context, source: String) {
        val missing = mutableListOf<String>()
        val accessibility = safeBool { ServiceDebugHelper.isAccessibilityServiceEnabledInSystem(context) }
        val notifications = safeBool {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        }
        val overlay = safeBool { Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context) }
        val battery = safeBool {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(context.packageName)
        }
        val exactAlarm = safeBool {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                alarmManager.canScheduleExactAlarms()
            } else {
                true
            }
        }
        if (!accessibility) missing.add("accessibility")
        if (!notifications) missing.add("notification")
        if (!overlay) missing.add("overlay")
        if (!battery) missing.add("battery_optimization")
        if (!exactAlarm) missing.add("exact_alarm")

        val critical = !accessibility
        val anyMissing = missing.isNotEmpty()
        recordStatus(
            context,
            component = COMPONENT_PERMISSIONS,
            status = if (!anyMissing) STATUS_OK else if (critical) STATUS_FAILED else STATUS_DEGRADED,
            severity = if (!anyMissing) SEVERITY_NONE else if (critical) SEVERITY_CRITICAL else SEVERITY_WARNING,
            countSuccess = !anyMissing,
            countFailure = anyMissing,
            eventType = if (anyMissing) "native_permission_missing" else "native_permission_check",
            errorType = if (anyMissing) "permission_missing" else null,
            errorMessage = if (anyMissing) "Missing permission: ${missing.joinToString(", ")}" else null,
            detail = mapOf(
                "source" to source,
                "accessibility" to accessibility,
                "notification" to notifications,
                "overlay" to overlay,
                "battery_optimization" to battery,
                "exact_alarm" to exactAlarm,
                "missing_permissions" to missing
            )
        )
    }

    private fun recordCaptureHealth(context: Context, source: String) {
        val enabled = UserSettingsStorage.getBoolean(
            context,
            UserSettingsKeysNative.SCREENSHOT_ENABLED,
            false,
            legacyPrefKeys = listOf("screenshot_enabled")
        )
        val interval = UserSettingsStorage.getInt(
            context,
            UserSettingsKeysNative.SCREENSHOT_INTERVAL,
            5,
            legacyPrefKeys = LegacySettingKeysNative.SCREENSHOT_INTERVAL
        ).coerceIn(1, 3600)
        val selectedCount = selectedAppCount(context)
        val serviceState = safeBool { ServiceStateManager.isAccessibilityServiceRunning(context) }
        val processRunning = safeBool { ServiceDebugHelper.isServiceProcessRunning(context) }
        val systemEnabled = safeBool { ServiceDebugHelper.isAccessibilityServiceEnabledInSystem(context) }
        val staticRunning = ScreenCaptureAccessibilityService.isServiceRunning
        val healthy = systemEnabled && (serviceState || processRunning || staticRunning)

        if (!enabled) {
            recordStatus(
                context,
                component = COMPONENT_CAPTURE,
                status = STATUS_DISABLED,
                severity = SEVERITY_NONE,
                eventType = "native_capture_disabled",
                detail = mapOf("source" to source, "enabled" to false, "selected_app_count" to selectedCount)
            )
            return
        }
        if (selectedCount == 0) {
            recordStatus(
                context,
                component = COMPONENT_CAPTURE,
                status = STATUS_DEGRADED,
                severity = SEVERITY_WARNING,
                countFailure = true,
                eventType = "native_capture_no_selected_apps",
                errorType = "capture_no_selected_apps",
                errorMessage = "No selected apps for screenshot capture",
                detail = mapOf("source" to source, "enabled" to true, "interval_sec" to interval)
            )
            return
        }

        recordStatus(
            context,
            component = COMPONENT_CAPTURE,
            status = if (healthy) STATUS_OK else STATUS_FAILED,
            severity = if (healthy) SEVERITY_NONE else SEVERITY_CRITICAL,
            countSuccess = healthy,
            countFailure = !healthy,
            eventType = if (healthy) "native_capture_check" else "native_capture_service_not_running",
            errorType = if (healthy) null else "capture_service_not_running",
            errorMessage = if (healthy) null else "Screenshot capture is enabled but service is not running",
            detail = mapOf(
                "source" to source,
                "enabled" to true,
                "interval_sec" to interval,
                "selected_app_count" to selectedCount,
                "system_enabled" to systemEnabled,
                "service_state" to serviceState,
                "process_running" to processRunning,
                "static_running" to staticRunning
            )
        )
    }

    private fun recordStorageHealth(context: Context, source: String) {
        try {
            val outputDir = File(context.filesDir, "output")
            if (!outputDir.exists()) outputDir.mkdirs()
            val probe = File(outputDir, ".app_health_probe")
            probe.writeText("ok")
            try { probe.delete() } catch (_: Throwable) {}
            val usable = outputDir.usableSpace
            val lowSpace = usable in 1 until (256L * 1024L * 1024L)
            recordStatus(
                context,
                component = COMPONENT_STORAGE,
                status = if (lowSpace) STATUS_DEGRADED else STATUS_OK,
                severity = if (lowSpace) SEVERITY_WARNING else SEVERITY_NONE,
                countSuccess = !lowSpace,
                countFailure = lowSpace,
                eventType = if (lowSpace) "native_storage_low" else "native_storage_check",
                errorType = if (lowSpace) "storage_low" else null,
                errorMessage = if (lowSpace) "Storage free space is low" else null,
                detail = mapOf("source" to source, "usable_bytes" to usable, "output_dir_available" to true)
            )
        } catch (t: Throwable) {
            recordStatus(
                context,
                component = COMPONENT_STORAGE,
                status = STATUS_FAILED,
                severity = SEVERITY_CRITICAL,
                countFailure = true,
                eventType = "native_storage_check_failed",
                errorType = "storage_check_failed",
                errorMessage = "Storage check failed: ${clip(t.message, 160) ?: t.javaClass.simpleName}",
                detail = mapOf("source" to source)
            )
        }
    }

    private fun recordBackgroundTaskHealth(context: Context, source: String) {
        try {
            val dynamicStatus = DynamicRebuildService.getTaskStatus(context)
            val importStatus = ImportOcrRepairService.getTaskStatus(context)
            val dynamic = dynamicStatus["status"]?.toString().orEmpty()
            val importing = importStatus["status"]?.toString().orEmpty()
            val dailyEnabled = UserSettingsStorage.getBoolean(
                context,
                UserSettingsKeysNative.DAILY_NOTIFY_ENABLED,
                true,
                legacyPrefKeys = listOf("daily_notify_enabled")
            )
            val failed = isFailedStatus(dynamic) || isFailedStatus(importing)
            val active = isActiveStatus(dynamic) || isActiveStatus(importing)
            val errorMessage = listOfNotNull(
                dynamicStatus["lastError"]?.toString()?.takeIf { it.isNotBlank() },
                importStatus["lastError"]?.toString()?.takeIf { it.isNotBlank() }
            ).firstOrNull()
            recordStatus(
                context,
                component = COMPONENT_BACKGROUND,
                status = if (failed) STATUS_DEGRADED else if (active) STATUS_IDLE else STATUS_OK,
                severity = if (failed) SEVERITY_WARNING else if (active) SEVERITY_INFO else SEVERITY_NONE,
                countSuccess = !failed && !active,
                countFailure = failed,
                eventType = if (failed) "native_background_task_failed" else "native_background_task_check",
                errorType = if (failed) "background_task_failed" else null,
                errorMessage = if (failed) (errorMessage ?: "Background task completed with failures") else null,
                detail = mapOf(
                    "source" to source,
                    "dynamic_rebuild_status" to (dynamic.ifBlank { "idle" }),
                    "import_ocr_status" to (importing.ifBlank { "idle" }),
                    "daily_notify_enabled" to dailyEnabled
                )
            )
        } catch (t: Throwable) {
            recordStatus(
                context,
                component = COMPONENT_BACKGROUND,
                status = STATUS_DEGRADED,
                severity = SEVERITY_WARNING,
                countFailure = true,
                eventType = "native_background_task_check_failed",
                errorType = "background_task_check_failed",
                errorMessage = "Background task check failed: ${clip(t.message, 160) ?: t.javaClass.simpleName}",
                detail = mapOf("source" to source)
            )
        }
    }

    private fun seedAiHealthIfMissing(context: Context, source: String) {
        var db: SQLiteDatabase? = null
        var cursor: Cursor? = null
        try {
            val path = ScreenshotDatabaseHelper.resolveMasterDbPath(context) ?: return
            db = SQLiteDatabase.openDatabase(path, null, SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY)
            ensureTables(db)
            cursor = db.query(
                "app_health_current",
                arrayOf("component"),
                "component = ?",
                arrayOf(COMPONENT_AI),
                null,
                null,
                null,
                "1"
            )
            if (cursor.moveToFirst()) return
            recordStatus(
                context,
                component = COMPONENT_AI,
                status = STATUS_IDLE,
                severity = SEVERITY_INFO,
                eventType = "native_ai_idle",
                detail = mapOf("source" to source, "message" to "No AI request recorded yet")
            )
        } catch (_: Throwable) {
        } finally {
            try { cursor?.close() } catch (_: Throwable) {}
            try { db?.close() } catch (_: Throwable) {}
        }
    }

    private fun ensureTables(db: SQLiteDatabase) {
        db.execSQL(
            """
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
            """.trimIndent()
        )
        db.execSQL(
            """
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
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_app_health_events_component_time ON app_health_events(component, created_at DESC)")
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_app_health_events_time ON app_health_events(created_at DESC)")
        db.execSQL(
            """
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
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_app_health_buckets_time ON app_health_buckets(bucket_start DESC)")
    }

    private fun queryCurrent(db: SQLiteDatabase, component: String): Map<String, Any?>? {
        var cursor: Cursor? = null
        return try {
            cursor = db.query(
                "app_health_current",
                null,
                "component = ?",
                arrayOf(component),
                null,
                null,
                null,
                "1"
            )
            if (!cursor.moveToFirst()) return null
            val result = HashMap<String, Any?>()
            for (i in 0 until cursor.columnCount) {
                val key = cursor.getColumnName(i)
                result[key] = when (cursor.getType(i)) {
                    Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(i)
                    Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(i)
                    Cursor.FIELD_TYPE_STRING -> cursor.getString(i)
                    Cursor.FIELD_TYPE_BLOB -> cursor.getBlob(i)
                    else -> null
                }
            }
            result
        } catch (_: Throwable) {
            null
        } finally {
            try { cursor?.close() } catch (_: Throwable) {}
        }
    }

    private fun upsertBucket(
        db: SQLiteDatabase,
        component: String,
        status: String,
        severity: Int,
        countSuccess: Boolean,
        countFailure: Boolean,
        errorType: String?,
        errorMessage: String?,
        now: Long
    ) {
        val bucketStart = now - (now % BASE_BUCKET_MS)
        val before = queryBucket(db, component, bucketStart)
        if (before == null) {
            db.execSQL(
                """
                INSERT INTO app_health_buckets(
                  component, bucket_start, status, severity, checked_count,
                  success_count, failure_count, last_error_type, last_error_message, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf<Any?>(
                    component,
                    bucketStart,
                    status,
                    severity,
                    1,
                    if (countSuccess) 1 else 0,
                    if (countFailure) 1 else 0,
                    errorType,
                    errorMessage,
                    now,
                )
            )
            return
        }
        val previousSeverity = asLong(before["severity"]).toInt()
        val newStatusWins = severity >= previousSeverity
        db.execSQL(
            """
            UPDATE app_health_buckets SET
              status = ?,
              severity = ?,
              checked_count = ?,
              success_count = ?,
              failure_count = ?,
              last_error_type = ?,
              last_error_message = ?,
              updated_at = ?
            WHERE component = ? AND bucket_start = ?
            """.trimIndent(),
            arrayOf<Any?>(
                if (newStatusWins) status else before["status"],
                max(previousSeverity, severity),
                asLong(before["checked_count"]) + 1L,
                asLong(before["success_count"]) + if (countSuccess) 1L else 0L,
                asLong(before["failure_count"]) + if (countFailure) 1L else 0L,
                errorType ?: before["last_error_type"],
                errorMessage ?: before["last_error_message"],
                now,
                component,
                bucketStart,
            )
        )
    }

    private fun queryBucket(db: SQLiteDatabase, component: String, bucketStart: Long): Map<String, Any?>? {
        var cursor: Cursor? = null
        return try {
            cursor = db.query(
                "app_health_buckets",
                null,
                "component = ? AND bucket_start = ?",
                arrayOf(component, bucketStart.toString()),
                null,
                null,
                null,
                "1"
            )
            if (!cursor.moveToFirst()) return null
            val result = HashMap<String, Any?>()
            for (i in 0 until cursor.columnCount) {
                val key = cursor.getColumnName(i)
                result[key] = when (cursor.getType(i)) {
                    Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(i)
                    Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(i)
                    Cursor.FIELD_TYPE_STRING -> cursor.getString(i)
                    Cursor.FIELD_TYPE_BLOB -> cursor.getBlob(i)
                    else -> null
                }
            }
            result
        } catch (_: Throwable) {
            null
        } finally {
            try { cursor?.close() } catch (_: Throwable) {}
        }
    }

    private fun selectedAppCount(context: Context): Int {
        val raw = firstNonBlank(
            safePrefString(context, "screen_memo_prefs", "selected_apps"),
            safePrefString(context, "FlutterSharedPreferences", "flutter.selected_apps"),
            safePrefString(context, "FlutterSharedPreferences", "selected_apps"),
            UserSettingsStorage.getString(context, "selected_apps", null),
        )
        if (raw.isNullOrBlank()) return 0
        return try {
            JSONArray(raw).length()
        } catch (_: Throwable) {
            raw.split(',').map { it.trim() }.filter { it.isNotBlank() }.size
        }
    }

    private fun safePrefString(context: Context, prefName: String, key: String): String? {
        return try {
            context.getSharedPreferences(prefName, Context.MODE_PRIVATE).getString(key, null)
        } catch (_: Throwable) {
            null
        }
    }

    private fun firstNonBlank(vararg values: String?): String? {
        return values.firstOrNull { !it.isNullOrBlank() }
    }

    private fun isActiveStatus(value: String): Boolean {
        val v = value.lowercase(Locale.US)
        return v == "preparing" || v == "running" || v == "resuming" || v == "collecting"
    }

    private fun isFailedStatus(value: String): Boolean {
        val v = value.lowercase(Locale.US)
        return v == "failed" || v == "completed_with_failures"
    }

    private fun safeBool(block: () -> Boolean): Boolean = try { block() } catch (_: Throwable) { false }

    private fun normalizeToken(value: String?): String {
        return value.orEmpty()
            .trim()
            .lowercase(Locale.US)
            .replace(Regex("[^a-z0-9_\\-]"), "_")
            .replace(Regex("_+"), "_")
    }

    private fun normalizeStatus(value: String): String {
        return when (val normalized = normalizeToken(value)) {
            STATUS_OK, STATUS_DEGRADED, STATUS_FAILED, STATUS_IDLE, STATUS_DISABLED, STATUS_NO_DATA -> normalized
            else -> STATUS_NO_DATA
        }
    }

    private fun asLong(value: Any?): Long {
        return when (value) {
            is Long -> value
            is Int -> value.toLong()
            is Number -> value.toLong()
            is String -> value.toLongOrNull() ?: 0L
            else -> 0L
        }
    }

    private fun clip(value: String?, maxLen: Int): String? {
        val text = value?.trim().orEmpty()
        if (text.isBlank()) return null
        return if (text.length <= maxLen) text else text.substring(0, maxLen)
    }

    private fun encodeDetail(detail: Map<String, Any?>?): String? {
        if (detail.isNullOrEmpty()) return null
        return try {
            val json = JSONObject()
            for ((key, value) in detail) {
                val cleanKey = normalizeToken(key)
                if (cleanKey.isBlank()) continue
                when (value) {
                    null -> json.put(cleanKey, JSONObject.NULL)
                    is Number, is Boolean -> json.put(cleanKey, value)
                    is Iterable<*> -> {
                        val arr = JSONArray()
                        value.forEach { item -> arr.put(clip(item?.toString(), 80) ?: JSONObject.NULL) }
                        json.put(cleanKey, arr)
                    }
                    else -> json.put(cleanKey, clip(value.toString(), 160))
                }
            }
            if (json.length() == 0) null else json.toString()
        } catch (_: Throwable) {
            null
        }
    }
}

