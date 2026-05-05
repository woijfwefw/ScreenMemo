package com.fqyw.screen_memo.health

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.fqyw.screen_memo.logging.FileLogger
import java.util.Timer
import kotlin.concurrent.timer

/**
 * App 运行状态调度器。
 *
 * - 进程存活时：Flutter Timer 与前台服务 Timer 都会按 1 分钟写入健康桶。
 * - 进程被系统回收后：AlarmManager 广播尽量每 1 分钟唤醒并补写结构化状态。
 * - Android 可能在省电 / 精确闹钟未授权 / 用户强行停止应用时限制触发。
 */
object AppHealthScheduler {
    private const val TAG = "AppHealthScheduler"
    const val ACTION_APP_HEALTH_ALARM = "com.fqyw.screen_memo.ACTION_APP_HEALTH_ALARM"
    private const val REQUEST_CODE = 4201
    private const val INTERVAL_MS = 60_000L

    @Volatile private var foregroundTimer: Timer? = null

    fun restore(context: Context) {
        val appContext = context.applicationContext ?: context
        scheduleNext(appContext)
    }

    fun scheduleNext(context: Context, delayMs: Long = INTERVAL_MS): Boolean {
        return try {
            val appContext = context.applicationContext ?: context
            val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = buildPendingIntent(appContext)
            val triggerAt = System.currentTimeMillis() + delayMs.coerceAtLeast(INTERVAL_MS)
            alarmManager.cancel(pendingIntent)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    if (alarmManager.canScheduleExactAlarms()) {
                        alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                    } else {
                        alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                    }
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                    alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                } else {
                    alarmManager.set(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                }
            } catch (_: Throwable) {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            }
            true
        } catch (t: Throwable) {
            try { FileLogger.w(TAG, "scheduleNext failed: ${t.message}") } catch (_: Throwable) {}
            false
        }
    }

    fun cancel(context: Context) {
        try {
            val appContext = context.applicationContext ?: context
            val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.cancel(buildPendingIntent(appContext))
        } catch (_: Throwable) {}
    }

    fun startForegroundHeartbeat(context: Context) {
        val appContext = context.applicationContext ?: context
        synchronized(this) {
            if (foregroundTimer != null) return
            foregroundTimer = timer(
                name = "AppHealthForegroundHeartbeat",
                daemon = true,
                initialDelay = INTERVAL_MS,
                period = INTERVAL_MS,
            ) {
                AppHealthNativeRecorder.recordSnapshot(appContext, "foreground_service_timer")
            }
        }
    }

    fun stopForegroundHeartbeat() {
        synchronized(this) {
            try { foregroundTimer?.cancel() } catch (_: Throwable) {}
            foregroundTimer = null
        }
    }

    private fun buildPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, AppHealthAlarmReceiver::class.java).apply {
            action = ACTION_APP_HEALTH_ALARM
            setPackage(context.packageName)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_CANCEL_CURRENT
        }
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }
}

class AppHealthAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AppHealthScheduler.ACTION_APP_HEALTH_ALARM) return
        val pending = goAsync()
        Thread {
            try {
                FileLogger.init(context)
                AppHealthNativeRecorder.recordSnapshot(context.applicationContext ?: context, "alarm_manager")
            } finally {
                try { AppHealthScheduler.scheduleNext(context.applicationContext ?: context) } catch (_: Throwable) {}
                pending.finish()
            }
        }.start()
    }
}
