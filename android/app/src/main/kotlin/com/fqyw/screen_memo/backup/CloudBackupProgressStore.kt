package com.fqyw.screen_memo.backup

import android.content.Context
import com.fqyw.screen_memo.settings.UserSettingsKeysNative
import com.fqyw.screen_memo.settings.UserSettingsStorage

data class CloudBackupProgress(
    val stage: String,
    val percent: Int,
    val detail: String,
    val updatedAt: Long,
    val bytesDone: Long = 0L,
    val bytesTotal: Long = 0L,
    val active: Boolean = false,
) {
    fun asMap(): Map<String, Any?> = mapOf(
        "stage" to stage,
        "percent" to percent.coerceIn(0, 100),
        "detail" to detail,
        "updatedAt" to updatedAt,
        "bytesDone" to bytesDone.coerceAtLeast(0L),
        "bytesTotal" to bytesTotal.coerceAtLeast(0L),
        "active" to active,
    )
}

object CloudBackupProgressStore {
    fun record(
        context: Context,
        stage: String,
        percent: Int,
        detail: String = "",
        bytesDone: Long = 0L,
        bytesTotal: Long = 0L,
        active: Boolean = true,
    ) {
        val appContext = context.applicationContext
        val now = System.currentTimeMillis()
        UserSettingsStorage.putString(appContext, UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_STAGE, stage)
        UserSettingsStorage.putInt(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_PERCENT,
            percent.coerceIn(0, 100),
        )
        UserSettingsStorage.putString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_DETAIL,
            detail.take(500),
        )
        UserSettingsStorage.putString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_UPDATED_AT,
            now.toString(),
        )
        UserSettingsStorage.putString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_BYTES_DONE,
            bytesDone.coerceAtLeast(0L).toString(),
        )
        UserSettingsStorage.putString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_BYTES_TOTAL,
            bytesTotal.coerceAtLeast(0L).toString(),
        )
        UserSettingsStorage.putBoolean(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_ACTIVE,
            active,
        )
    }

    fun markInactive(context: Context, stage: String, percent: Int, detail: String = "") {
        record(
            context = context,
            stage = stage,
            percent = percent,
            detail = detail,
            active = false,
        )
    }

    fun read(context: Context): CloudBackupProgress {
        val appContext = context.applicationContext
        return CloudBackupProgress(
            stage = UserSettingsStorage.getString(
                appContext,
                UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_STAGE,
                "",
            ).orEmpty(),
            percent = UserSettingsStorage.getInt(
                appContext,
                UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_PERCENT,
                0,
            ).coerceIn(0, 100),
            detail = UserSettingsStorage.getString(
                appContext,
                UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_DETAIL,
                "",
            ).orEmpty(),
            updatedAt = UserSettingsStorage.getString(
                appContext,
                UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_UPDATED_AT,
                "0",
            )?.toLongOrNull() ?: 0L,
            bytesDone = UserSettingsStorage.getString(
                appContext,
                UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_BYTES_DONE,
                "0",
            )?.toLongOrNull() ?: 0L,
            bytesTotal = UserSettingsStorage.getString(
                appContext,
                UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_BYTES_TOTAL,
                "0",
            )?.toLongOrNull() ?: 0L,
            active = UserSettingsStorage.getBoolean(
                appContext,
                UserSettingsKeysNative.CLOUD_BACKUP_PROGRESS_ACTIVE,
                false,
            ),
        )
    }
}
