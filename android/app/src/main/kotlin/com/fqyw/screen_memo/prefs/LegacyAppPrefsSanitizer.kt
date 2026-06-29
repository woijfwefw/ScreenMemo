package com.fqyw.screen_memo.prefs

import android.content.Context
import com.fqyw.screen_memo.logging.OutputFileLogger

/**
 * 清理旧版写入 SharedPreferences 的超大应用列表缓存。
 *
 * 旧实现会把每个应用图标编码进 all_apps_cache / selected_apps /
 * app_identity_cache。用户安装应用很多（例如 1200+）时，这些字符串可达
 * 几十到上百 MB；Flutter 的 shared_preferences 在 getInstance() 时会把整份
 * SharedPreferences 通过 MethodChannel 解码，容易在 Flutter worker 线程 OOM。
 *
 * 该清理必须在 FlutterEngine 启动前执行，否则 Dart 侧迁移代码可能还没运行就崩溃。
 */
object LegacyAppPrefsSanitizer {
    private const val TAG = "LegacyAppPrefsSanitizer"
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val MAX_SAFE_CHARS = 512 * 1024

    private val appPayloadKeys = listOf(
        "flutter.all_apps_cache",
        "flutter.selected_apps",
        "flutter.app_identity_cache",
        // 兼容极旧版本未加 flutter. 前缀的键。
        "all_apps_cache",
        "selected_apps",
        "app_identity_cache",
    )

    private val appCacheTsKeys = listOf(
        "flutter.all_apps_cache_ts",
        "all_apps_cache_ts",
    )

    fun sanitize(context: Context) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val editor = prefs.edit()
            var changed = 0
            val changedDetails = mutableListOf<String>()

            for (key in appPayloadKeys) {
                val raw = prefs.getString(key, null) ?: continue
                val shouldSanitize =
                    raw.length > MAX_SAFE_CHARS ||
                        raw.contains("\"icon\":\"") ||
                        raw.contains("\"icon\": \"")
                if (!shouldSanitize) continue

                val sanitized = stripIconFields(raw)
                if (!sanitized.isNullOrBlank() &&
                    sanitized.length < raw.length &&
                    sanitized.length <= MAX_SAFE_CHARS
                ) {
                    editor.putString(key, sanitized)
                    changedDetails += "$key:${raw.length}->${sanitized.length}"
                } else {
                    // 极端异常数据无法安全瘦身时再删除，避免继续 OOM。
                    editor.remove(key)
                    changedDetails += "$key:${raw.length}->removed"
                }
                changed += 1
            }

            if (changed > 0) {
                for (key in appCacheTsKeys) {
                    editor.remove(key)
                }
                editor.commit()
                OutputFileLogger.infoForce(
                    context,
                    TAG,
                    "sanitized_legacy_app_prefs count=$changed details=${changedDetails.joinToString(",")}"
                )
            }
        } catch (t: Throwable) {
            try {
                OutputFileLogger.errorForce(
                    context,
                    TAG,
                    "sanitize_failed type=${t.javaClass.name} message=${t.message ?: "-"}"
                )
            } catch (_: Throwable) {
                // 启动前清理不能影响应用启动。
            }
        }
    }

    /**
     * 用轻量扫描移除 JSON 对象里的 icon 字段，避免 JSONArray 解析超大 base64 字符串时
     * 再次制造数倍内存峰值。输入是 Dart jsonEncode 生成的数组/对象，字段顺序通常为
     * packageName/appName/version/.../icon。
     */
    private fun stripIconFields(raw: String): String? {
        val out = StringBuilder(raw.length.coerceAtMost(MAX_SAFE_CHARS))
        var lastKeep = 0
        var searchFrom = 0
        var removed = false

        while (searchFrom < raw.length) {
            val keyStart = raw.indexOf("\"icon\"", searchFrom)
            if (keyStart < 0) break

            val before = previousNonWhitespace(raw, keyStart - 1)
            val keyEnd = keyStart + "\"icon\"".length
            val colon = nextNonWhitespace(raw, keyEnd)
            if ((before < 0 || (raw[before] != ',' && raw[before] != '{')) ||
                colon < 0 ||
                raw[colon] != ':'
            ) {
                searchFrom = keyEnd
                continue
            }

            val valueStart = nextNonWhitespace(raw, colon + 1)
            if (valueStart < 0) break
            var valueEnd = skipJsonValue(raw, valueStart)
            if (valueEnd <= valueStart) {
                searchFrom = keyEnd
                continue
            }

            val removeStart: Int
            if (raw[before] == ',') {
                removeStart = before
            } else {
                removeStart = keyStart
                val afterValue = nextNonWhitespace(raw, valueEnd)
                if (afterValue >= 0 && raw[afterValue] == ',') {
                    valueEnd = afterValue + 1
                }
            }

            if (removeStart >= lastKeep) {
                out.append(raw, lastKeep, removeStart)
                lastKeep = valueEnd
                removed = true
            }
            searchFrom = valueEnd
        }

        if (!removed) return null
        out.append(raw, lastKeep, raw.length)
        return out.toString()
    }

    private fun previousNonWhitespace(text: String, start: Int): Int {
        var i = start
        while (i >= 0 && text[i].isWhitespace()) i -= 1
        return i
    }

    private fun nextNonWhitespace(text: String, start: Int): Int {
        var i = start
        while (i < text.length && text[i].isWhitespace()) i += 1
        return if (i < text.length) i else -1
    }

    private fun skipJsonValue(text: String, start: Int): Int {
        return when (text[start]) {
            '"' -> skipJsonString(text, start)
            '{' -> skipBalanced(text, start, '{', '}')
            '[' -> skipBalanced(text, start, '[', ']')
            else -> {
                var i = start
                while (i < text.length && text[i] != ',' && text[i] != '}' && text[i] != ']') {
                    i += 1
                }
                i
            }
        }
    }

    private fun skipJsonString(text: String, start: Int): Int {
        var i = start + 1
        var escaped = false
        while (i < text.length) {
            val c = text[i]
            if (escaped) {
                escaped = false
            } else if (c == '\\') {
                escaped = true
            } else if (c == '"') {
                return i + 1
            }
            i += 1
        }
        return text.length
    }

    private fun skipBalanced(text: String, start: Int, open: Char, close: Char): Int {
        var i = start
        var depth = 0
        while (i < text.length) {
            when (text[i]) {
                '"' -> i = skipJsonString(text, i) - 1
                open -> depth += 1
                close -> {
                    depth -= 1
                    if (depth <= 0) return i + 1
                }
            }
            i += 1
        }
        return text.length
    }
}
