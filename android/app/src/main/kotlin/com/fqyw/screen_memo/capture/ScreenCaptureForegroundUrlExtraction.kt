package com.fqyw.screen_memo.capture

import android.view.accessibility.AccessibilityNodeInfo
import com.fqyw.screen_memo.logging.FileLogger

private const val TAG = "ScreenCaptureService"

/**
 * 安全提取当前页面URL（启发式）：
 * - 遍历无障碍树，查找位于屏幕上方区域的文本节点/可编辑节点；
 * - 使用URL正则匹配 http/https；
 * - 不进行浏览器包名硬编码。
 */
internal fun ScreenCaptureAccessibilityService.extractCurrentPageUrlSafe(): String? {
    return try {
        val root = rootInActiveWindow
        if (root == null) {
            FileLogger.d(TAG, "extractURL: rootInActiveWindow 为 null")
            return null
        }
        val display = resources.displayMetrics
        val screenH = display.heightPixels
        val topThreshold = (screenH * 0.25f).toInt() // 仅在顶部四分之一区域查找
        FileLogger.d(TAG, "extractURL: screenH=${screenH}, topThreshold=${topThreshold}")

        val queue: ArrayDeque<AccessibilityNodeInfo> = ArrayDeque()
        queue.add(root)
        var bestUrl: String? = null
        var bestY = Int.MAX_VALUE
        var visited = 0
        var matched = 0
        var loggedSamples = 0

        fun candidateText(node: AccessibilityNodeInfo): String? {
            val sb = StringBuilder()
            try {
                val t = node.text?.toString()
                if (!t.isNullOrBlank()) sb.append(t)
            } catch (_: Exception) {}
            try {
                val cd = node.contentDescription?.toString()
                if (!cd.isNullOrBlank()) {
                    if (sb.isNotEmpty()) sb.append(' ')
                    sb.append(cd)
                }
            } catch (_: Exception) {}
            val s = sb.toString().trim()
            return if (s.isEmpty()) null else s
        }

        // 主要匹配：显式 http/https 链接（更稳健，避免字符类嵌套导致转义问题）
        val urlRegex = Regex("(?i)\\bhttps?://[^\\s\"<>]+")

        // 回退匹配：无 scheme 的域名（如 example.com/path），命中则默认补全为 https://
        val domainFallback = Regex("(?i)\\b((?:[a-z0-9-]+\\.)+[a-z]{2,})(?:/[\\S]*)?")

        while (queue.isNotEmpty()) {
            val n = queue.removeFirst()
            visited++
            try {
                val rect = android.graphics.Rect()
                n.getBoundsInScreen(rect)
                val y = rect.top
                if (y in 0..topThreshold) {
                    val text = candidateText(n)
                    if (!text.isNullOrEmpty()) {
                        val m = urlRegex.find(text)
                        if (m != null) {
                            matched++
                            if (loggedSamples < 5) {
                                val snippet = if (text.length > 120) text.substring(0, 120) + "…" else text
                                FileLogger.d(TAG, "extractURL: 命中候选 y=${y}, url='${m.value}', text='${snippet}'")
                                loggedSamples++
                            }
                            if (y < bestY) {
                                bestY = y
                                bestUrl = m.value
                            }
                        } else if (bestUrl == null) {
                            // 仅在尚未命中显式URL时，尝试域名回退
                            val dm = domainFallback.find(text)
                            if (dm != null) {
                                val reconstructed = "https://" + dm.value
                                if (loggedSamples < 5) {
                                    val snippet = if (text.length > 120) text.substring(0, 120) + "…" else text
                                    FileLogger.d(TAG, "extractURL: 回退命中 y=${y}, domain='${dm.value}', url='${reconstructed}', text='${snippet}'")
                                    loggedSamples++
                                }
                                if (y < bestY) {
                                    bestY = y
                                    bestUrl = reconstructed
                                }
                            }
                        }
                    }
                }
                for (i in 0 until (n.childCount ?: 0)) {
                    val c = n.getChild(i)
                    if (c != null) queue.add(c)
                }
            } catch (_: Exception) {
            }
        }
        if (bestUrl != null) {
            FileLogger.i(TAG, "extractURL: 选定最优 url='${bestUrl}', y=${bestY}, visited=${visited}, matched=${matched}")
        } else {
            FileLogger.i(TAG, "extractURL: 未找到URL, visited=${visited}, matched=${matched}")
        }
        bestUrl
    } catch (e: Exception) {
        FileLogger.e(TAG, "extractURL 异常", e)
        null
    }
}
