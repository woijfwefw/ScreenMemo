package com.fqyw.screen_memo.segment

import android.content.Context
import com.fqyw.screen_memo.settings.AISettingsNative
import org.json.JSONObject

internal data class JsonFixMeta(
    val retryCount: Int,
    val jsonFix: String,
    val needsManualRetry: Boolean,
    val retryMessage: String
)

internal fun readSegmentsJsonAutoRetryMax(ctx: Context): Int {
    return try {
        val raw = AISettingsNative.readSettingValue(ctx, "segments_json_auto_retry_max")?.trim()
        val parsed = raw?.toIntOrNull()
        val v = parsed ?: 1
        v.coerceIn(0, 5)
    } catch (_: Exception) {
        1
    }
}

internal fun applyJsonFixMeta(root: JSONObject, meta: JsonFixMeta): JSONObject {
    return try {
        val m = JSONObject()
        m.put("retry_count", meta.retryCount)
        m.put("json_fix", meta.jsonFix)
        m.put("needs_manual_retry", meta.needsManualRetry)
        if (meta.retryMessage.isNotBlank()) {
            m.put("retry_message", meta.retryMessage)
        }
        root.put("_meta", m)
        root
    } catch (_: Exception) {
        root
    }
}

internal fun repairStructuredJson(text: String): String? {
    val raw = text.trim()
    if (raw.isEmpty()) return null

    val fenced = extractFencedJson(raw)
    val balanced = extractBalancedJsonObject(fenced ?: raw)
    val candidate = (balanced ?: fenced ?: raw).trim()
    if (candidate.isEmpty()) return null

    val passes = ArrayList<String>()
    passes.add(candidate)
    passes.add(candidate.replace(Regex(",\\s*([}\\]])"), "$1"))

    val closed = closeJsonCandidate(candidate)
    if (closed != null && closed != candidate) {
        passes.add(closed)
        passes.add(closed.replace(Regex(",\\s*([}\\]])"), "$1"))
    }

    for (p in passes) {
        val t = p.trim()
        if (t.isEmpty()) continue
        try {
            JSONObject(t)
            return t
        } catch (_: Exception) {
        }
    }
    return null
}

internal fun extractFencedJson(text: String): String? {
    val rg = Regex("```(?:json)?\\s*([\\s\\S]*?)\\s*```", RegexOption.IGNORE_CASE)
    val m = rg.find(text) ?: return null
    return m.groupValues.getOrNull(1)?.trim()
}

internal fun extractBalancedJsonObject(text: String): String? {
    val s = text.trim()
    val start = s.indexOf('{')
    if (start < 0) return null
    var depth = 0
    var inStr = false
    var escaped = false
    var end = -1
    for (i in start until s.length) {
        val ch = s[i]
        if (escaped) {
            escaped = false
            continue
        }
        if (ch == '\\') {
            if (inStr) escaped = true
            continue
        }
        if (ch == '"') {
            inStr = !inStr
            continue
        }
        if (inStr) continue
        if (ch == '{') depth++
        if (ch == '}') {
            depth--
            if (depth == 0) {
                end = i
                break
            }
        }
    }
    if (end > start) return s.substring(start, end + 1)
    return null
}

internal fun closeJsonCandidate(candidate: String): String? {
    var s = candidate.trim()
    if (s.isEmpty()) return null
    val start = s.indexOf('{')
    if (start < 0) return null
    s = s.substring(start)

    var inStr = false
    var escaped = false
    var openObj = 0
    var openArr = 0
    val out = StringBuilder(s.length + 8)
    for (ch in s) {
        out.append(ch)
        if (escaped) {
            escaped = false
            continue
        }
        if (ch == '\\') {
            if (inStr) escaped = true
            continue
        }
        if (ch == '"') {
            inStr = !inStr
            continue
        }
        if (inStr) continue
        when (ch) {
            '{' -> openObj++
            '}' -> if (openObj > 0) openObj--
            '[' -> openArr++
            ']' -> if (openArr > 0) openArr--
        }
    }

    if (inStr) out.append('"')
    while (openArr > 0) {
        out.append(']')
        openArr--
    }
    while (openObj > 0) {
        out.append('}')
        openObj--
    }
    return out.toString().replace(Regex(",\\s*([}\\]])"), "$1")
}

internal fun buildJsonRepairRetryPrompt(originalPrompt: String, brokenOutput: String): String {
    val original = originalPrompt.trim()
    val broken = truncateForLog(brokenOutput, 12000)
    return """
$original

【系统补救任务】
你上一条回复的 JSON 不完整或不可解析。请在不改变业务含义的前提下，重新输出一份完整、可解析的 JSON。

严格要求：
- 只输出单个 JSON 对象，不要输出任何解释文字。
- 不要使用 Markdown 代码块围栏（不要 ```json）。
- 保留既有字段结构与语义（apps/categories/timeline/key_actions/content_groups/overall_summary/image_tags/image_descriptions/described_images 等）。
- image_tags 和 image_descriptions 必须保持可用。

上一次（损坏）输出片段如下（仅供修复参考）：
$broken
""".trim()
}
