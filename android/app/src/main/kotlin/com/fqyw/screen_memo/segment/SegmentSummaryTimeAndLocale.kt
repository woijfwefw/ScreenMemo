package com.fqyw.screen_memo.segment

import android.content.Context

internal fun dateKeyFromMillis(ms: Long): String {
    val cal = java.util.Calendar.getInstance().apply { timeInMillis = ms }
    val y = cal.get(java.util.Calendar.YEAR).toString().padStart(4, '0')
    val m = (cal.get(java.util.Calendar.MONTH) + 1).toString().padStart(2, '0')
    val d = cal.get(java.util.Calendar.DAY_OF_MONTH).toString().padStart(2, '0')
    return "$y-$m-$d"
}

internal fun getStringByLang(
    ctx: Context,
    lang: String,
    zhId: Int,
    enId: Int,
    jaId: Int,
    koId: Int,
): String {
    return when (lang) {
        "zh" -> ctx.getString(zhId)
        "ja" -> ctx.getString(jaId)
        "ko" -> ctx.getString(koId)
        else -> ctx.getString(enId)
    }
}

internal fun startOfToday(): Long {
    val cal = java.util.Calendar.getInstance()
    cal.set(java.util.Calendar.HOUR_OF_DAY, 0)
    cal.set(java.util.Calendar.MINUTE, 0)
    cal.set(java.util.Calendar.SECOND, 0)
    cal.set(java.util.Calendar.MILLISECOND, 0)
    return cal.timeInMillis
}

internal fun endOfToday(): Long {
    val cal = java.util.Calendar.getInstance()
    cal.set(java.util.Calendar.HOUR_OF_DAY, 23)
    cal.set(java.util.Calendar.MINUTE, 59)
    cal.set(java.util.Calendar.SECOND, 59)
    cal.set(java.util.Calendar.MILLISECOND, 999)
    return cal.timeInMillis
}
