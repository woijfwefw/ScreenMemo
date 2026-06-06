package com.fqyw.screen_memo.segment

import android.content.Context
import com.fqyw.screen_memo.R
import com.fqyw.screen_memo.database.SegmentDatabaseHelper
import com.fqyw.screen_memo.settings.AISettingsNative
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
internal fun mergeSamples(
    a: List<SegmentDatabaseHelper.Sample>,
    b: List<SegmentDatabaseHelper.Sample>
): List<SegmentDatabaseHelper.Sample> {
    val all = (a + b).sortedBy { it.captureTime }
    val seen = HashSet<String>()
    val res = ArrayList<SegmentDatabaseHelper.Sample>(all.size)
    var pos = 0
    for (s in all) {
        if (seen.add(s.filePath)) {
            res.add(s.copy(positionIndex = pos++))
        }
    }
    return res
}
internal data class ImageDescEntry(
    val from: String,
    val to: String,
    val description: String
)

internal fun extractImageDescriptions(structuredJson: String?): List<ImageDescEntry> {
    val sj = structuredJson?.trim()
    if (sj.isNullOrEmpty() || sj.equals("null", ignoreCase = true)) return emptyList()
    return try {
        val root = JSONObject(sj)
        val arr = root.optJSONArray("image_descriptions") ?: return emptyList()
        val out = ArrayList<ImageDescEntry>(arr.length())
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val from = obj.optString("from_file", obj.optString("from", obj.optString("start", ""))).trim()
            val to = obj.optString("to_file", obj.optString("to", obj.optString("end", ""))).trim()
            val desc = obj.optString("description", obj.optString("desc", "")).trim()
            if (desc.isEmpty()) continue
            val a = if (from.isNotEmpty()) from else to
            val b = if (to.isNotEmpty()) to else from
            if (a.isEmpty() || b.isEmpty()) continue
            out.add(ImageDescEntry(from = a, to = b, description = desc))
        }
        out
    } catch (_: Exception) {
        emptyList()
    }
}

internal data class MergeAiInputPlan(
    val aiSamples: List<SegmentDatabaseHelper.Sample>,
    val textOnlyDescriptions: List<ImageDescEntry>
)

internal fun buildDescByFileFromStructuredJson(
    structuredJson: String?,
    samples: List<SegmentDatabaseHelper.Sample>
): Map<String, String> {
    if (samples.isEmpty()) return emptyMap()
    val list = extractImageDescriptions(structuredJson)
    if (list.isEmpty()) return emptyMap()

    val ordered = samples.sortedBy { it.captureTime }
    val files = ArrayList<String>(ordered.size)
    val indexByFile = HashMap<String, Int>(ordered.size * 2)
    for ((i, s) in ordered.withIndex()) {
        val name = try { File(s.filePath).name } catch (_: Exception) { "" }
        if (name.isEmpty()) continue
        files.add(name)
        indexByFile.putIfAbsent(name, i)
    }
    if (files.isEmpty()) return emptyMap()

    val descByFile = HashMap<String, String>(files.size * 2)
    for (e in list) {
        val ia = indexByFile[e.from] ?: continue
        val ib = indexByFile[e.to] ?: continue
        var start = ia
        var end = ib
        if (start > end) {
            val tmp = start
            start = end
            end = tmp
        }
        for (k in start..end) {
            if (k < 0 || k >= files.size) continue
            val f = files[k]
            if (!descByFile.containsKey(f)) {
                descByFile[f] = e.description
            }
        }
    }
    return descByFile
}

internal fun buildTextOnlyDescriptionRanges(
    orderedFiles: List<String>,
    descByFile: Map<String, String>,
    excludedFiles: Set<String>
): List<ImageDescEntry> {
    if (orderedFiles.isEmpty() || descByFile.isEmpty()) return emptyList()
    val out = ArrayList<ImageDescEntry>()
    var rangeStartFile: String? = null
    var rangeEndFile: String? = null
    var currentDesc: String? = null

    fun flush() {
        val a = rangeStartFile
        val b = rangeEndFile
        val d = currentDesc
        if (!a.isNullOrBlank() && !b.isNullOrBlank() && !d.isNullOrBlank()) {
            out.add(ImageDescEntry(from = a, to = b, description = d))
        }
        rangeStartFile = null
        rangeEndFile = null
        currentDesc = null
    }

    for (f in orderedFiles) {
        if (excludedFiles.contains(f)) {
            flush()
            continue
        }
        val d = (descByFile[f] ?: "").trim()
        if (d.isEmpty()) {
            flush()
            continue
        }
        if (currentDesc == null) {
            rangeStartFile = f
            rangeEndFile = f
            currentDesc = d
            continue
        }
        if (d == currentDesc) {
            rangeEndFile = f
        } else {
            flush()
            rangeStartFile = f
            rangeEndFile = f
            currentDesc = d
        }
    }
    flush()

    return out
}

internal fun normalizeTextOnlyDescriptionForMergePrompt(text: String): String {
    return text
        .replace("\r\n", "\n")
        .replace('\r', '\n')
        .replace(Regex("[ \\t]+"), " ")
        .replace(Regex("\\n{3,}"), "\n\n")
        .trim()
}

internal fun normalizeAndDedupTextOnlyDescriptionsForMergePrompt(
    descriptions: List<String>,
): List<String> {
    if (descriptions.isEmpty()) return emptyList()
    val out = ArrayList<String>(descriptions.size)
    val seen = LinkedHashSet<String>()
    for (raw in descriptions) {
        val normalized = normalizeTextOnlyDescriptionForMergePrompt(raw)
        if (normalized.isEmpty()) continue
        if (seen.add(normalized)) {
            out.add(normalized)
        }
    }
    return out
}

internal fun limitTextOnlyDescriptionsForMergePrompt(
    descriptions: List<String>,
    maxEntries: Int,
    maxChars: Int,
): List<String> {
    if (descriptions.isEmpty() || maxEntries <= 0 || maxChars <= 0) return emptyList()
    val out = ArrayList<String>(kotlin.math.min(descriptions.size, maxEntries))
    var usedChars = 0
    for (desc in descriptions) {
        if (out.size >= maxEntries) break
        if (out.isEmpty()) {
            if (desc.length > maxChars) {
                out.add(truncateForLog(desc, maxChars))
                break
            }
            out.add(desc)
            usedChars = desc.length
            continue
        }
        val projected = usedChars + 3 + desc.length
        if (projected > maxChars) break
        out.add(desc)
        usedChars = projected
    }
    return out
}

internal fun planMergeAiInput(
    allSamples: List<SegmentDatabaseHelper.Sample>,
    prevStructuredJson: String?,
    prevSamples: List<SegmentDatabaseHelper.Sample>,
    curStructuredJson: String?,
    curSamples: List<SegmentDatabaseHelper.Sample>,
    maxAiImages: Int
): MergeAiInputPlan {
    val cap = maxAiImages.coerceAtLeast(1)
    if (allSamples.isEmpty()) return MergeAiInputPlan(aiSamples = emptyList(), textOnlyDescriptions = emptyList())

    val prevDesc = buildDescByFileFromStructuredJson(prevStructuredJson, prevSamples)
    val curDesc = buildDescByFileFromStructuredJson(curStructuredJson, curSamples)
    val descByFile = HashMap<String, String>(prevDesc.size + curDesc.size + 8)
    descByFile.putAll(prevDesc)
    descByFile.putAll(curDesc)

    val ordered = allSamples.sortedBy { it.captureTime }
    val withDesc = ArrayList<SegmentDatabaseHelper.Sample>(ordered.size)
    val withoutDesc = ArrayList<SegmentDatabaseHelper.Sample>(ordered.size)
    for (s in ordered) {
        val name = try { File(s.filePath).name } catch (_: Exception) { "" }
        val d = (descByFile[name] ?: "").trim()
        if (d.isEmpty()) withoutDesc.add(s) else withDesc.add(s)
    }

    val chosenUndescribed =
        if (withoutDesc.size > cap) evenPick(withoutDesc, cap) else withoutDesc
    val remaining = cap - chosenUndescribed.size
    val chosenDescribed = when {
        remaining <= 0 -> emptyList()
        withDesc.size > remaining -> evenPick(withDesc, remaining)
        else -> withDesc
    }

    val aiSamples = (chosenUndescribed + chosenDescribed)
        .sortedBy { it.captureTime }
        .mapIndexed { idx, s -> s.copy(positionIndex = idx) }

    val excludedFiles = HashSet<String>(aiSamples.size * 2)
    for (s in aiSamples) {
        val name = try { File(s.filePath).name } catch (_: Exception) { "" }
        if (name.isNotEmpty()) excludedFiles.add(name)
    }
    val orderedFiles = ordered.mapNotNull { s ->
        val name = try { File(s.filePath).name } catch (_: Exception) { "" }
        name.takeIf { it.isNotEmpty() }
    }
    val textOnlyRanges = buildTextOnlyDescriptionRanges(
        orderedFiles = orderedFiles,
        descByFile = descByFile,
        excludedFiles = excludedFiles
    )

    return MergeAiInputPlan(aiSamples = aiSamples, textOnlyDescriptions = textOnlyRanges)
}

internal data class ImageTagEntry(
    val file: String,
    val refTime: String?,
    val app: String?,
    val tags: List<String>
)

internal fun extractImageTags(structuredJson: String?): Map<String, ImageTagEntry> {
    val sj = structuredJson?.trim()
    if (sj.isNullOrEmpty() || sj.equals("null", ignoreCase = true)) return emptyMap()
    return try {
        val root = JSONObject(sj)
        val arr = root.optJSONArray("image_tags") ?: return emptyMap()
        val out = HashMap<String, ImageTagEntry>(arr.length() * 2)
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val file = obj.optString("file", "").trim()
            if (file.isEmpty()) continue
            val app = obj.optString("app", "").trim().ifEmpty { null }
            val ref = obj.optString("ref_time", obj.optString("time", "")).trim().ifEmpty { null }
            val raw = obj.opt("tags")
            val tags = ArrayList<String>()
            when (raw) {
                is JSONArray -> {
                    for (j in 0 until raw.length()) {
                        val t = raw.optString(j, "").trim()
                        if (t.isNotEmpty()) tags.add(t)
                    }
                }
                is String -> {
                    raw.split(Regex("[，,;；\\s]+"))
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                        .forEach { tags.add(it) }
                }
            }
            val cleaned = tags.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
            if (cleaned.isEmpty()) continue
            out[file] = ImageTagEntry(file = file, refTime = ref, app = app, tags = cleaned)
        }
        out
    } catch (_: Exception) {
        emptyMap()
    }
}

internal fun mergeImageDescriptionsIntoStructuredJson(
    mergedStructuredJson: String?,
    mergedSamplesForUi: List<SegmentDatabaseHelper.Sample>,
    mergedAiSamples: List<SegmentDatabaseHelper.Sample>,
    prevStructuredJson: String?,
    prevSamples: List<SegmentDatabaseHelper.Sample>,
    curStructuredJson: String?,
    curSamples: List<SegmentDatabaseHelper.Sample>
): String? {
    val sj = mergedStructuredJson?.trim()
    if (mergedSamplesForUi.isEmpty()) return mergedStructuredJson

    val root = when {
        sj.isNullOrEmpty() || sj.equals("null", ignoreCase = true) -> JSONObject()
        else -> try { JSONObject(sj) } catch (_: Exception) { return mergedStructuredJson }
    }

    val ordered = mergedSamplesForUi.sortedBy { it.captureTime }
    val files = ArrayList<String>(ordered.size)
    val indexByFile = HashMap<String, Int>(ordered.size * 2)
    val sampleByFile = HashMap<String, SegmentDatabaseHelper.Sample>(ordered.size * 2)
    for ((i, s) in ordered.withIndex()) {
        val name = try { File(s.filePath).name } catch (_: Exception) { "" }
        if (name.isEmpty()) continue
        files.add(name)
        indexByFile.putIfAbsent(name, i)
        sampleByFile.putIfAbsent(name, s)
    }
    if (files.isEmpty()) return mergedStructuredJson

    fun buildFileSet(samples: List<SegmentDatabaseHelper.Sample>): Set<String> {
        val set = HashSet<String>(samples.size * 2)
        for (s in samples) {
            val name = try { File(s.filePath).name } catch (_: Exception) { "" }
            if (name.isNotEmpty()) set.add(name)
        }
        return set
    }

    val descByFile = HashMap<String, String>(files.size * 2)

    fun applyDescriptions(structuredJson: String?, sourceFileSet: Set<String>, overwrite: Boolean) {
        val list = extractImageDescriptions(structuredJson)
        if (list.isEmpty()) return
        for (e in list) {
            val a = e.from
            val b = e.to
            val desc = e.description
            val ia = indexByFile[a]
            val ib = indexByFile[b]
            if (ia == null || ib == null) continue

            var start = ia
            var end = ib
            if (start > end) {
                val tmp = start
                start = end
                end = tmp
            }

            for (k in start..end) {
                if (k < 0 || k >= files.size) continue
                val f = files[k]
                if (!sourceFileSet.contains(f)) continue
                if (!overwrite && descByFile.containsKey(f)) continue
                descByFile[f] = desc
            }
        }
    }

    // 合并提示词生成的描述优先级最低：仅用于填补缺失，避免覆盖原事件更细的描述
    applyDescriptions(mergedStructuredJson, buildFileSet(mergedAiSamples), overwrite = false)
    applyDescriptions(prevStructuredJson, buildFileSet(prevSamples), overwrite = true)
    applyDescriptions(curStructuredJson, buildFileSet(curSamples), overwrite = true)

    // 合并 image_tags：用于缩略图 NSFW 遮罩与详情展示，避免合并后 tags 缺失
    val tagByFile = HashMap<String, ImageTagEntry>(files.size * 2)

    fun applyTags(structuredJson: String?, sourceFileSet: Set<String>, overwrite: Boolean) {
        val map = extractImageTags(structuredJson)
        if (map.isEmpty()) return
        for ((file, entry) in map) {
            if (!sourceFileSet.contains(file)) continue
            if (!overwrite && tagByFile.containsKey(file)) continue
            tagByFile[file] = entry
        }
    }

    applyTags(mergedStructuredJson, buildFileSet(mergedAiSamples), overwrite = false)
    applyTags(prevStructuredJson, buildFileSet(prevSamples), overwrite = true)
    applyTags(curStructuredJson, buildFileSet(curSamples), overwrite = true)

    val tagArr = JSONArray()
    for (f in files) {
        val entry = tagByFile[f] ?: continue
        val sample = sampleByFile[f]
        val tags = entry.tags
        if (tags.isEmpty()) continue
        val obj = JSONObject()
        obj.put("file", f)
        val app = (entry.app?.trim()?.takeIf { it.isNotEmpty() }
            ?: sample?.appName?.trim()?.takeIf { it.isNotEmpty() }
            ?: sample?.appPackageName?.trim()?.takeIf { it.isNotEmpty() }
            ?: "")
        if (app.isNotEmpty()) obj.put("app", app)
        val refTime = (entry.refTime?.trim()?.takeIf { it.isNotEmpty() }
            ?: (sample?.captureTime?.let { SegmentSummaryManager.fmt(it) } ?: ""))
        if (refTime.isNotEmpty()) obj.put("ref_time", refTime)
        val ja = JSONArray()
        for (t in tags) ja.put(t)
        obj.put("tags", ja)
        tagArr.put(obj)
    }
    if (tagArr.length() > 0) {
        root.put("image_tags", tagArr)
    }

    // 压缩为不重叠的连续 range，确保每个文件最多落入一个描述范围
    val outArr = JSONArray()
    var rangeStartFile: String? = null
    var rangeEndFile: String? = null
    var currentDesc: String? = null

    fun flush() {
        val a = rangeStartFile
        val b = rangeEndFile
        val d = currentDesc
        if (!a.isNullOrBlank() && !b.isNullOrBlank() && !d.isNullOrBlank()) {
            val obj = JSONObject()
            obj.put("from_file", a)
            obj.put("to_file", b)
            obj.put("description", d)
            outArr.put(obj)
        }
        rangeStartFile = null
        rangeEndFile = null
        currentDesc = null
    }

    for (f in files) {
        val d = (descByFile[f] ?: "").trim()
        if (d.isEmpty()) {
            flush()
            continue
        }
        if (currentDesc == null) {
            rangeStartFile = f
            rangeEndFile = f
            currentDesc = d
            continue
        }
        if (d == currentDesc) {
            rangeEndFile = f
        } else {
            flush()
            rangeStartFile = f
            rangeEndFile = f
            currentDesc = d
        }
    }
    flush()

    if (outArr.length() > 0) {
        root.put("image_descriptions", outArr)
    }
    return root.toString()
}

internal fun extractOverallSummary(text: String): String {
    val start = text.indexOf("overall_summary")
    if (start < 0) return text.take(200)
    val brace = text.indexOf('{', start)
    val endBrace = text.lastIndexOf('}')
    if (brace >= 0 && endBrace > brace) {
        val json = text.substring(brace, endBrace + 1)
        return try {
            val o = org.json.JSONObject(json)
            o.optString("overall_summary", text.take(200))
        } catch (_: Exception) { text.take(200) }
    }
    return text.take(200)
}

internal fun buildMergePrompt(
    ctx: Context,
    a: SegmentDatabaseHelper.Segment,
    b: SegmentDatabaseHelper.Segment,
    samples: List<SegmentDatabaseHelper.Sample>,
    textOnlyDescriptions: List<ImageDescEntry> = emptyList(),
    totalImages: Int? = null,
    maxAttachedImages: Int? = null,
    forced: Boolean = false,
    slimImageMetadata: Boolean = false,
): String {
    val orderedForPrompt = samples.sortedBy { it.captureTime }

    // 依据应用语言注入"语言强制策略"并选择合并提示词（支持 _zh/_en 与旧键回退）
    val langOpt = try { ctx.getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE).getString("flutter.locale_option", "system") } catch (_: Exception) { "system" }
    val sysLang = try { java.util.Locale.getDefault().language?.lowercase() } catch (_: Exception) { "en" } ?: "en"
    val effectiveLang = when (langOpt) {
        "zh", "en", "ja", "ko" -> langOpt
        "system" -> when {
            sysLang.startsWith("zh") -> "zh"
            sysLang.startsWith("ja") -> "ja"
            sysLang.startsWith("ko") -> "ko"
            else -> "en"
        }
        else -> "en"
    }
    val isZhLang = effectiveLang == "zh"

    val extraHeader = try { AISettingsNative.readSettingValue(ctx, if (isZhLang) "prompt_merge_extra_zh" else "prompt_merge_extra_en") } catch (_: Exception) { null }
    val legacyHeaderLang = try { AISettingsNative.readSettingValue(ctx, if (isZhLang) "prompt_merge_zh" else "prompt_merge_en") } catch (_: Exception) { null }
    val legacyHeader = try { AISettingsNative.readSettingValue(ctx, "prompt_merge") } catch (_: Exception) { null }

    val defaultHeaderZh =
        "请基于以下图片产出合并后的总结；必须遵循以下规则（中文输出，结构化JSON，行为导向，禁止逐图/禁止OCR）：\n" +
        "- 禁止使用OCR文本，直接理解图片内容；\n" +
        "- 不要对每张图片逐条描述；请产出用户在该时间段的'行为总结'，如 浏览/观看/聊天/购物/办公/设置/下载/分享/游戏 等，按应用或主题整合；\n" +
        "- 对包含视频标题、作者、品牌等独特信息，按屏幕原样保留；\n" +
        "- 对同一文章/视频/页面的连续图片，归为同一 content_group，做整体总结；\n" +
        "- 开头先输出一段对本时间段的简短总结（纯文本，不使用任何标题；不要出现\\\"## 概览\\\"或\\\"## 总结\\\"等）；随后再使用 Markdown 小节呈现后续内容；\n" +
        "- Markdown 要求：所有\"用于展示的文本字段\"须使用 Markdown（overall_summary 与 content_groups[].summary），用小标题与项目符号清晰呈现；禁止输出 Markdown 代码块标记（如 ```），仅纯 Markdown 文本；\n" +
        "- overall_summary 必须按以下固定顺序包含且只能包含这三个二级标题：\"## 关键操作\"、\"## 主要活动\"、\"## 重点内容\"。每个小节必须使用 \"- \" 输出至少 3 条要点；如信息不足，仍必须保留该小节并至少提供 1 条有意义的占位要点；不得省略、改名或调整顺序。\n" +
        "- 在\"## 关键操作\"中，将相邻/连续同类行为合并为区间，格式\"HH:mm:ss-HH:mm:ss：行为描述\"（例如\"08:16:41-08:27:21：浏览视频评论\"）；仅在行为中断或切换时新起一条；控制 3-8 条精要；\n" +
        "- 为尽可能保留信息，可在 Markdown 中使用无序/有序列表、加粗/斜体与内联代码高亮（但不要使用代码块）；\n" +
        "- 不要重新生成 image_tags[] 与 image_descriptions[]；系统会沿用原事件已有的图片标签与图片描述。\n" +
        "以 JSON 输出以下字段（与普通事件保持一致，不要省略字段名）：apps[], categories[], timeline[], key_actions[], content_groups[], overall_summary；\n" +
        "字段约定：\n" +
        "key_actions[]: [{\"type\":\"pay|login|register|permission_grant|oauth_authorize|purchase|bind_account|unbind_account|captcha|biometric|other\",\"app\":\"应用名\",\"ref_image\":\"图片序号字符串\",\"ref_time\":\"HH:mm:ss\",\"detail\":\"简要说明（避免敏感信息）\",\"confidence\":0.0}],\n" +
        "content_groups[]: [{\"group_type\":\"article|video|page|playlist|feed\",\"title\":\"可为空\",\"app\":\"应用名\",\"start_time\":\"HH:mm:ss\",\"end_time\":\"HH:mm:ss\",\"image_count\":1,\"representative_images\":[\"图片序号字符串1\",\"图片序号字符串2\"],\"summary\":\"本组内容的Markdown要点\"}],\n" +
        "timeline[]: [{\"time\":\"HH:mm:ss\",\"app\":\"应用名\",\"action\":\"浏览|观看|聊天|购物|搜索|编辑|游戏|设置|下载|分享|其他\",\"summary\":\"一句话行为（可用简短Markdown强调）\"}],\n" +
        "overall_summary: \"开头为无标题的一段总结，随后使用Markdown小节与要点，保留多事件合并后的关键信息\"；\n" +
        "仅输出一个 JSON 对象，不要附加解释或 JSON 外的 Markdown；所有展示性内容（含后续小节）请写入 overall_summary 字段的 Markdown"

    val defaultHeaderEn =
        "Please produce a merged summary for the following images. MUST follow (English output, structured JSON, behavior-focused, no per-image narration / no OCR):\n" +
        "- Do NOT use OCR; understand images directly.\n" +
        "- Do not describe each image; output a 'behavior summary' over the period (browse/watch/chat/shop/work/settings/download/share/game, etc.), grouped by app/topic.\n" +
        "- Preserve unique on-screen info (video titles/authors/brands) as seen.\n" +
        "- Merge consecutive images from the same article/video/page into one content_group and summarize holistically.\n" +
        "- Start with one plain paragraph (no headings) summarizing the period; then present details using Markdown sections.\n" +
        "- Markdown requirements: all display texts use Markdown (overall_summary and content_groups[].summary); headings and bullet points for clarity; NO code fences (```), only pure Markdown.\n" +
        "- overall_summary MUST include exactly these three second-level sections in this fixed order:\n" +
        "  \\\"## Key Actions\\\"\\n  \\\"## Main Activities\\\"\\n  \\\"## Key Content\\\"\\n" +
        "  Each section MUST contain at least 3 bullet points using \\\"- \\\". If context is insufficient, still keep the section and provide at least 1 meaningful placeholder bullet. Do not omit or rename sections.\n" +
        "- In \"## Key Actions\", merge adjacent same-type actions into ranges \"HH:mm:ss-HH:mm:ss: description\"; only new item when action breaks; keep 3–8 concise lines.\n" +
        "- content_groups[].summary uses 1–3 Markdown bullets for group topic/representative titles/intent.\n" +
        "- Do NOT regenerate image_tags[] or image_descriptions[]; the system will carry over image tags and descriptions from the original events.\n" +
        "Output JSON fields (same as normal event): apps[], categories[], timeline[], key_actions[], content_groups[], overall_summary.\n" +
        "Only output ONE JSON object; no explanations or Markdown outside JSON; all display content belongs to overall_summary (Markdown)."

    val defaultHeaderJa =
        "以下の画像を基に統合サマリーを作成してください。必ず次のルールに従ってください（日本語出力、構造化JSON、行動重視、逐一説明禁止／OCR禁止）:\n" +
        "- OCR文字起こしは使わず、画像内容を直接理解してください。\n" +
        "- 各画像を1枚ずつ説明せず、この時間帯の行動をアプリ／話題ごとに統合して要約してください。\n" +
        "- 動画タイトル、作者、ブランドなど固有情報は画面表示どおり保持してください。\n" +
        "- 同じ記事／動画／ページの連続画像は1つの content_group にまとめて扱ってください。\n" +
        "- 冒頭は見出しなしの短い段落、その後は Markdown 小見出しと箇条書きで整理してください。\n" +
        "- overall_summary には \"## 主要アクション\"、\"## 主な活動\"、\"## 重要コンテンツ\" の3つをこの順で含めてください。\n" +
        "- image_tags[] と image_descriptions[] は再生成しないでください。元イベントの画像タグと説明はシステム側で引き継ぎます。\n" +
        "JSON では apps[], categories[], timeline[], key_actions[], content_groups[], overall_summary を出力してください。"

    val defaultHeaderKo =
        "다음 이미지를 바탕으로 병합 요약을 생성하세요. 다음 규칙을 반드시 지키세요(한국어 출력, 구조화 JSON, 행동 중심, 이미지별 서술 금지/OCR 금지):\n" +
        "- OCR 텍스트를 사용하지 말고 이미지 내용을 직접 이해하세요.\n" +
        "- 이미지를 하나씩 설명하지 말고, 이 시간대의 행동을 앱/주제별로 통합 요약하세요.\n" +
        "- 영상 제목, 작성자, 브랜드 같은 고유 정보는 화면 그대로 유지하세요.\n" +
        "- 같은 글/영상/페이지의 연속 이미지는 하나의 content_group 으로 묶어 다루세요.\n" +
        "- 시작은 제목 없는 짧은 단락으로, 이후는 Markdown 소제목과 불릿으로 정리하세요.\n" +
        "- overall_summary 에는 \"## 주요 행동\", \"## 주요 활동\", \"## 핵심 콘텐츠\" 3개 섹션을 이 순서대로 포함하세요.\n" +
        "- image_tags[] 와 image_descriptions[] 는 다시 생성하지 마세요. 원본 이벤트의 이미지 태그와 설명은 시스템이 이어받습니다.\n" +
        "JSON 에서는 apps[], categories[], timeline[], key_actions[], content_groups[], overall_summary 를 출력하세요。"

    val languagePolicy = getStringByLang(
        ctx,
        effectiveLang,
        R.string.ai_language_policy_zh,
        R.string.ai_language_policy_en,
        R.string.ai_language_policy_ja,
        R.string.ai_language_policy_ko
    )
    val baseHeader =
        if (slimImageMetadata) {
            when (effectiveLang) {
                "zh" -> defaultHeaderZh
                "ja" -> defaultHeaderJa
                "ko" -> defaultHeaderKo
                else -> defaultHeaderEn
            }
        } else {
            getStringByLang(
                ctx,
                effectiveLang,
                R.string.merge_prompt_default_zh,
                R.string.merge_prompt_default_en,
                R.string.merge_prompt_default_ja,
                R.string.merge_prompt_default_ko
            )
        }
    val addon = sequenceOf(extraHeader, legacyHeaderLang, legacyHeader)
        .firstOrNull { it != null && it.trim().isNotEmpty() }
        ?.trim()
    val headerBuilder = StringBuilder()
    headerBuilder.append(languagePolicy).append("\n\n").append(baseHeader)
    if (!addon.isNullOrEmpty()) {
        val label = when (effectiveLang) {
            "zh" -> "附加说明："
            "ja" -> "追加指示："
            "ko" -> "추가 지침:"
            else -> "Additional instructions:"
        }
        headerBuilder.append("\n\n").append(label).append('\n').append(addon)
    }
    val header = headerBuilder.toString()

    val sb = StringBuilder()
    val titleLabel = getStringByLang(ctx, effectiveLang, R.string.title_merged_event_summary_zh, R.string.title_merged_event_summary_en, R.string.title_merged_event_summary_ja, R.string.title_merged_event_summary_ko)
    val timeRangeLabel = getStringByLang(ctx, effectiveLang, R.string.label_time_range_zh, R.string.label_time_range_en, R.string.label_time_range_ja, R.string.label_time_range_ko)
    val shotLabel = getStringByLang(ctx, effectiveLang, R.string.label_screenshot_at_zh, R.string.label_screenshot_at_en, R.string.label_screenshot_at_ja, R.string.label_screenshot_at_ko)
    val imageIndexLabel = when (effectiveLang) {
        "zh" -> "图片索引（仅使用序号引用图片）"
        "ja" -> "画像インデックス（画像参照は番号のみ）"
        "ko" -> "이미지 인덱스(번호로만 참조)"
        else -> "Image index list (reference by number only)"
    }

    sb.append(header).append('\n')
    sb.append(titleLabel).append('\n')
        .append(timeRangeLabel)
        .append(SegmentSummaryManager.fmt(kotlin.math.min(a.startTime, b.startTime)))
        .append(" - ")
        .append(SegmentSummaryManager.fmt(kotlin.math.max(a.endTime, b.endTime)))
        .append('\n')
    run {
        val provided = samples.size
        val total = totalImages ?: provided
        val cap = (maxAttachedImages ?: SegmentSummaryManager.PROVIDER_IMAGE_HARD_LIMIT).coerceAtLeast(1)
        val note = when (effectiveLang) {
            "zh" ->
                "注意：受模型图片数量限制，本次仅附带 $provided 张图片（上限 $cap）。本事件共涉及 $total 张图片；未附带的图片若已有历史描述，将在末尾以文字形式提供，供合并总结时参考。对“仅文字描述”的部分，请不要凭空补全画面细节。"
            else ->
                "Note: due to the model image limit, this request attaches only $provided images (max $cap). This merged event contains $total images; for the rest, existing descriptions (if any) are provided below as text-only context. For text-only descriptions, do not invent extra visual details."
        }
        sb.append(note).append('\n').append('\n')
        if (forced) {
            val forcedNote = when (effectiveLang) {
                "zh" -> "用户已确认需要强制合并：请直接生成合并后的总结，不需要判断是否属于同一事件。"
                else -> "User confirmed a forced merge: directly produce the merged summary; do not judge whether they are the same event."
            }
            sb.append(forcedNote).append('\n').append('\n')
        }
    }
    sb.append(imageIndexLabel).append('\n')
    for ((idx, s) in orderedForPrompt.withIndex()) {
        val appDisplay = s.appName.trim().ifEmpty { s.appPackageName.trim() }
        sb.append(shotLabel)
            .append("[#").append(idx + 1).append("] ")
            .append(SegmentSummaryManager.fmt(s.captureTime))
            .append(" | ")
            .append(appDisplay)
            .append('\n')
    }
    val promptTextOnlyDescriptions =
        if (slimImageMetadata) {
            val normalizedUnique = normalizeAndDedupTextOnlyDescriptionsForMergePrompt(
                textOnlyDescriptions.map { it.description }
            )
            limitTextOnlyDescriptionsForMergePrompt(
                normalizedUnique,
                maxEntries = 6,
                maxChars = 4200,
            )
        } else {
            textOnlyDescriptions.mapNotNull {
                it.description.trim().takeIf { desc -> desc.isNotEmpty() }
            }
        }
    if (promptTextOnlyDescriptions.isNotEmpty()) {
        val label = when (effectiveLang) {
            "zh" -> "以下图片不发送原图，仅提供已有描述（请将描述视为事实，不要自行扩写）："
            else -> "The following images are NOT attached; only existing descriptions are provided (treat as facts; do not expand/hallucinate):"
        }
        sb.append('\n').append(label).append('\n')
        for (desc in promptTextOnlyDescriptions) {
            sb.append("- ").append(desc).append('\n')
        }
        if (slimImageMetadata) {
            val omitted = textOnlyDescriptions.size - promptTextOnlyDescriptions.size
            if (omitted > 0) {
                val note = when (effectiveLang) {
                    "zh" -> "说明：其余 $omitted 条未附带图片的历史描述因重复或篇幅限制已省略；请仅基于已提供信息整合，不要脑补被省略图片的具体画面。"
                    "ja" -> "補足：残り $omitted 件の未添付画像の説明は、重複または長さ制限のため省略しています。省略分の具体的な画面を想像で補わないでください。"
                    "ko" -> "참고: 나머지 ${omitted}개의 미첨부 이미지 설명은 중복 또는 길이 제한 때문에 생략했습니다. 생략된 이미지의 구체적 화면을 추측해서 보완하지 마세요."
                    else -> "Note: the remaining $omitted text-only image descriptions were omitted because of duplication or prompt-size limits. Do not invent specific visual details for those omitted images."
                }
                sb.append(note).append('\n')
            }
        }
    }
    return sb.toString()
}
