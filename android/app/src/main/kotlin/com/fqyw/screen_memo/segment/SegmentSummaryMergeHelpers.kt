package com.fqyw.screen_memo.segment

import com.fqyw.screen_memo.database.SegmentDatabaseHelper
import com.fqyw.screen_memo.logging.FileLogger
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

// SegmentSummaryManager 的合并、结构化 JSON 与图片引用辅助逻辑。
internal data class TextFirstMergedResult(
    val outputText: String,
    val structuredJson: String,
    val categoriesJson: String?
)

internal fun parseStructuredJsonObject(structuredJson: String?): JSONObject? {
    val sj = structuredJson?.trim()
    if (sj.isNullOrEmpty() || sj.equals("null", ignoreCase = true)) return null
    return try { JSONObject(sj) } catch (_: Exception) { null }
}

internal data class ImageRefResolution(
    val value: String?,
    val numericLike: Boolean
)

internal fun resolveImageRefValue(raw: Any?, indexToFile: List<String>): ImageRefResolution {
    if (raw == null) return ImageRefResolution(value = null, numericLike = false)
    if (raw is Number) {
        val idx = raw.toInt()
        return if (idx in 1..indexToFile.size) {
            ImageRefResolution(value = indexToFile[idx - 1], numericLike = true)
        } else {
            ImageRefResolution(value = null, numericLike = true)
        }
    }

    val text = raw.toString().trim()
    if (text.isEmpty()) return ImageRefResolution(value = "", numericLike = false)
    val m = Regex("^#?(\\d+)$").matchEntire(text)
    if (m != null) {
        val idx = m.groupValues.getOrNull(1)?.toIntOrNull()
        return if (idx != null && idx in 1..indexToFile.size) {
            ImageRefResolution(value = indexToFile[idx - 1], numericLike = true)
        } else {
            ImageRefResolution(value = null, numericLike = true)
        }
    }
    return ImageRefResolution(value = text, numericLike = false)
}

internal fun normalizeImageRefsToFilenames(
    structuredJson: String?,
    samples: List<SegmentDatabaseHelper.Sample>
): String? {
    val sj = structuredJson?.trim()
    if (sj.isNullOrEmpty() || sj.equals("null", ignoreCase = true)) return structuredJson
    if (samples.isEmpty()) return structuredJson

    val root = try {
        JSONObject(sj)
    } catch (_: Exception) {
        return structuredJson
    }

    val ordered = samples.sortedBy { it.captureTime }
    val indexToFile = ArrayList<String>(ordered.size)
    for (s in ordered) {
        val name = try { File(s.filePath).name } catch (_: Exception) { "" }
        if (name.isNotEmpty()) indexToFile.add(name)
    }
    if (indexToFile.isEmpty()) return structuredJson

    var changed = false

    fun logInvalid(field: String, raw: Any?) {
        try {
            FileLogger.w(
                "SegmentSummaryManager",
                "normalizeImageRefs: invalid image index field=$field raw=${raw?.toString() ?: "null"} max=${indexToFile.size}"
            )
        } catch (_: Exception) {
        }
    }

    fun normalizeSingleRef(obj: JSONObject, key: String, fieldLabel: String): Boolean {
        if (!obj.has(key)) return false
        val raw = obj.opt(key)
        val resolved = resolveImageRefValue(raw, indexToFile)
        if (resolved.numericLike) {
            val mapped = resolved.value
            if (mapped.isNullOrBlank()) {
                obj.remove(key)
                logInvalid(fieldLabel, raw)
                return true
            }
            if (obj.optString(key, "") != mapped) {
                obj.put(key, mapped)
                return true
            }
            return false
        }

        val keep = resolved.value?.trim().orEmpty()
        if (keep.isEmpty()) return false
        if (obj.optString(key, "") != keep) {
            obj.put(key, keep)
            return true
        }
        return false
    }

    fun resolveBoundary(
        obj: JSONObject,
        primaryKey: String,
        aliasKeys: List<String>,
        fieldLabel: String
    ): String? {
        val keys = ArrayList<String>(1 + aliasKeys.size)
        keys.add(primaryKey)
        keys.addAll(aliasKeys)

        var hasAny = false
        var raw: Any? = null
        for (k in keys) {
            if (obj.has(k)) {
                hasAny = true
                raw = obj.opt(k)
                break
            }
        }
        if (!hasAny) return null

        val resolved = resolveImageRefValue(raw, indexToFile)
        if (resolved.numericLike && resolved.value.isNullOrBlank()) {
            logInvalid(fieldLabel, raw)
            return ""
        }
        val out = resolved.value?.trim().orEmpty()
        if (out.isEmpty()) return ""

        if (obj.optString(primaryKey, "") != out) {
            obj.put(primaryKey, out)
            changed = true
        }
        for (k in aliasKeys) {
            if (obj.has(k)) {
                obj.remove(k)
                changed = true
            }
        }
        return out
    }

    run {
        val arr = root.optJSONArray("image_tags")
        if (arr != null) {
            val out = JSONArray()
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val hadFile = obj.has("file")
                if (normalizeSingleRef(obj, "file", "image_tags[$i].file")) changed = true
                if (hadFile && !obj.has("file")) {
                    changed = true
                    continue
                }
                out.put(obj)
            }
            if (out.length() != arr.length()) {
                root.put("image_tags", out)
                changed = true
            }
        }
    }

    run {
        val arr = root.optJSONArray("image_descriptions")
        if (arr != null) {
            val out = JSONArray()
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val hasBoundary = obj.has("from_file") || obj.has("from") || obj.has("start") ||
                    obj.has("to_file") || obj.has("to") || obj.has("end")
                if (!hasBoundary) {
                    out.put(obj)
                    continue
                }

                val from = resolveBoundary(
                    obj,
                    primaryKey = "from_file",
                    aliasKeys = listOf("from", "start"),
                    fieldLabel = "image_descriptions[$i].from_file"
                )
                val to = resolveBoundary(
                    obj,
                    primaryKey = "to_file",
                    aliasKeys = listOf("to", "end"),
                    fieldLabel = "image_descriptions[$i].to_file"
                )

                val a = if (!from.isNullOrEmpty()) from else to
                val b = if (!to.isNullOrEmpty()) to else from
                if (a.isNullOrEmpty() || b.isNullOrEmpty()) {
                    changed = true
                    continue
                }

                if (obj.optString("from_file", "") != a) {
                    obj.put("from_file", a)
                    changed = true
                }
                if (obj.optString("to_file", "") != b) {
                    obj.put("to_file", b)
                    changed = true
                }
                out.put(obj)
            }

            if (out.length() != arr.length()) {
                root.put("image_descriptions", out)
                changed = true
            }
        }
    }

    run {
        val arr = root.optJSONArray("described_images")
        if (arr != null) {
            val out = JSONArray()
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val hadFile = obj.has("file")
                if (normalizeSingleRef(obj, "file", "described_images[$i].file")) changed = true
                if (hadFile && !obj.has("file")) {
                    changed = true
                    continue
                }
                out.put(obj)
            }
            if (out.length() != arr.length()) {
                root.put("described_images", out)
                changed = true
            }
        }
    }

    run {
        val arr = root.optJSONArray("key_actions")
        if (arr != null) {
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                if (normalizeSingleRef(obj, "ref_image", "key_actions[$i].ref_image")) changed = true
            }
        }
    }

    run {
        val arr = root.optJSONArray("content_groups")
        if (arr != null) {
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val reps = obj.optJSONArray("representative_images") ?: continue
                val out = JSONArray()
                for (j in 0 until reps.length()) {
                    val raw = reps.opt(j)
                    val resolved = resolveImageRefValue(raw, indexToFile)
                    val mapped = resolved.value?.trim().orEmpty()
                    if (resolved.numericLike && mapped.isEmpty()) {
                        logInvalid("content_groups[$i].representative_images[$j]", raw)
                        changed = true
                        continue
                    }
                    if (mapped.isEmpty()) {
                        changed = true
                        continue
                    }
                    if (raw?.toString()?.trim() != mapped) {
                        changed = true
                    }
                    out.put(mapped)
                }
                if (out.length() != reps.length()) changed = true
                obj.put("representative_images", out)
            }
        }
    }

    return if (changed) root.toString() else structuredJson
}

internal fun readStringList(obj: JSONObject?, key: String): List<String> {
    val arr = obj?.optJSONArray(key) ?: return emptyList()
    val out = ArrayList<String>(arr.length())
    for (i in 0 until arr.length()) {
        val v = arr.optString(i, "").trim()
        if (v.isNotEmpty() && !v.equals("null", ignoreCase = true)) out.add(v)
    }
    return out
}

internal fun mergeUniqueStrings(a: List<String>, b: List<String>): List<String> {
    val seen = LinkedHashSet<String>()
    for (s in a) {
        val v = s.trim()
        if (v.isNotEmpty()) seen.add(v)
    }
    for (s in b) {
        val v = s.trim()
        if (v.isNotEmpty()) seen.add(v)
    }
    return ArrayList(seen)
}

internal fun concatJsonArrays(a: JSONArray?, b: JSONArray?): JSONArray {
    val out = JSONArray()
    if (a != null) {
        for (i in 0 until a.length()) out.put(a.opt(i))
    }
    if (b != null) {
        for (i in 0 until b.length()) out.put(b.opt(i))
    }
    return out
}

internal fun pickNonEmpty(vararg candidates: String?): String {
    for (c in candidates) {
        val t = c?.trim()
        if (!t.isNullOrEmpty() && !t.equals("null", ignoreCase = true)) return t
    }
    return ""
}

internal fun extractOverallSummaryFromStructuredOrText(obj: JSONObject?, fallbackText: String?): String {
    val fromStructured = obj?.optString("overall_summary", "")?.trim()
    if (!fromStructured.isNullOrEmpty() && !fromStructured.equals("null", ignoreCase = true)) return fromStructured
    return pickNonEmpty(fallbackText)
}

internal fun splitMergedEventSummaryParts(summary: String): List<String> {
    val t = summary.trim()
    if (t.isEmpty() || t.equals("null", ignoreCase = true)) return emptyList()
    val normalized = summary.replace("\r\n", "\n").replace("\r", "\n")
    val parts = normalized.split(Regex("^\\s*---+\\s*$", RegexOption.MULTILINE))
    val out = ArrayList<String>(parts.size)
    for (p in parts) {
        val v = p.trim()
        if (v.isNotEmpty() && !v.equals("null", ignoreCase = true)) out.add(v)
    }
    return out
}

internal fun extractOriginalSummaryPartsForMerge(outputText: String?, structuredJson: String?): List<String> {
    val obj = parseStructuredJsonObject(structuredJson)
    val overall = extractOverallSummaryFromStructuredOrText(obj, outputText)
    val parts = splitMergedEventSummaryParts(overall)
    if (parts.isEmpty()) return emptyList()
    // 若 summary 已包含 `---` 分隔，则第一段为“合并后的摘要”，后续为“原始事件摘要”
    return if (parts.size > 1) parts.drop(1) else parts
}

internal fun attachOriginalSummariesToMergedResult(
    mergedOutputText: String,
    mergedStructuredJson: String?,
    prevOriginals: List<String>,
    curOriginals: List<String>
): Pair<String, String?> {
    val originals = ArrayList<String>(prevOriginals.size + curOriginals.size)
    for (s in prevOriginals) {
        val v = s.trim()
        if (v.isNotEmpty()) originals.add(v)
    }
    for (s in curOriginals) {
        val v = s.trim()
        if (v.isNotEmpty()) originals.add(v)
    }
    if (originals.isEmpty()) return Pair(mergedOutputText, mergedStructuredJson)

    val mergedObj = parseStructuredJsonObject(mergedStructuredJson)
    val mergedOverall = extractOverallSummaryFromStructuredOrText(mergedObj, mergedOutputText)
    val mergedParts = splitMergedEventSummaryParts(mergedOverall)
    if (mergedParts.size > 1) {
        // 已包含原始事件，避免重复追加
        return Pair(mergedOutputText, mergedStructuredJson)
    }

    val main = (mergedParts.firstOrNull() ?: mergedOverall).trim()
    val sb = StringBuilder()
    if (main.isNotEmpty()) sb.append(main) else sb.append(mergedOverall.trim())
    for (o in originals) {
        sb.append("\n\n---\n\n").append(o)
    }
    val combinedOverall = sb.toString()

    var outStructured: String? = mergedStructuredJson
    var outText = mergedOutputText
    if (mergedObj != null) {
        try {
            mergedObj.put("overall_summary", combinedOverall)
            outStructured = mergedObj.toString()
        } catch (_: Exception) {
        }
    } else {
        // structured_json 缺失时：退化为在 output_text 里追加分隔内容，保证前端仍能拆分展示
        val sb2 = StringBuilder()
        val head = mergedOutputText.trim()
        if (head.isNotEmpty() && !head.equals("null", ignoreCase = true)) {
            sb2.append(head)
        } else if (main.isNotEmpty()) {
            sb2.append(main)
        }
        for (o in originals) {
            sb2.append("\n\n---\n\n").append(o)
        }
        outText = sb2.toString()
    }
    return Pair(outText, outStructured)
}

internal fun buildTextFirstMergedResult(
    prevOutputText: String,
    prevStructuredJson: String?,
    curOutputText: String,
    curStructuredJson: String?
): TextFirstMergedResult {
    val prevObj = parseStructuredJsonObject(prevStructuredJson)
    val curObj = parseStructuredJsonObject(curStructuredJson)

    val apps = mergeUniqueStrings(readStringList(prevObj, "apps"), readStringList(curObj, "apps"))
    val categories = mergeUniqueStrings(readStringList(prevObj, "categories"), readStringList(curObj, "categories"))

    val timeline = concatJsonArrays(prevObj?.optJSONArray("timeline"), curObj?.optJSONArray("timeline"))
    val keyActions = concatJsonArrays(prevObj?.optJSONArray("key_actions"), curObj?.optJSONArray("key_actions"))
    val contentGroups = concatJsonArrays(prevObj?.optJSONArray("content_groups"), curObj?.optJSONArray("content_groups"))

    val prevOverall = extractOverallSummaryFromStructuredOrText(prevObj, prevOutputText)
    val curOverall = extractOverallSummaryFromStructuredOrText(curObj, curOutputText)
    val mergedOverall = when {
        prevOverall.isNotEmpty() && curOverall.isNotEmpty() -> prevOverall + "\n\n---\n\n" + curOverall
        prevOverall.isNotEmpty() -> prevOverall
        else -> curOverall
    }

    val appsArr = JSONArray()
    for (v in apps) appsArr.put(v)
    val catArr = JSONArray()
    for (v in categories) catArr.put(v)

    val merged = JSONObject()
    merged.put("apps", appsArr)
    merged.put("categories", catArr)
    merged.put("timeline", timeline)
    merged.put("key_actions", keyActions)
    merged.put("content_groups", contentGroups)
    merged.put("overall_summary", mergedOverall)

    val categoriesJson = if (categories.isNotEmpty()) catArr.toString() else null
    val outputText = pickNonEmpty(mergedOverall, curOverall, prevOverall)
    return TextFirstMergedResult(
        outputText = outputText,
        structuredJson = merged.toString(),
        categoriesJson = categoriesJson
    )
}

internal fun truncateForLog(text: String, maxLen: Int = 3000): String {
    return if (text.length <= maxLen) text else (text.substring(0, maxLen) + "…<truncated>")
}

internal fun pickCompareImages(
    a: List<SegmentDatabaseHelper.Sample>,
    b: List<SegmentDatabaseHelper.Sample>,
    cap: Int
): Pair<List<SegmentDatabaseHelper.Sample>, List<SegmentDatabaseHelper.Sample>> {
    val maxCap = cap.coerceAtLeast(1)
    val total = a.size + b.size
    if (total <= maxCap) return Pair(a, b)
    val half = maxCap / 2
    return Pair(evenPick(a, half), evenPick(b, maxCap - half))
}

internal fun evenPick(list: List<SegmentDatabaseHelper.Sample>, count: Int): List<SegmentDatabaseHelper.Sample> {
    if (list.isEmpty() || count <= 0) return emptyList()
    if (list.size <= count) return list
    val step = list.size.toDouble() / count
    val out = ArrayList<SegmentDatabaseHelper.Sample>(count)
    var idx = 0.0
    while (out.size < count) {
        out.add(list[idx.toInt().coerceIn(0, list.size - 1)])
        idx += step
    }
    return out
}
