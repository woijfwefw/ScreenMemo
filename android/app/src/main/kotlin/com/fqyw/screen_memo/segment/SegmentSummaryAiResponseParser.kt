package com.fqyw.screen_memo.segment

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

internal fun appendReasoningPiece(buffer: StringBuilder, piece: String?) {
    val raw = piece ?: ""
    if (raw.trim().isEmpty()) return
    if (buffer.isNotEmpty() &&
        buffer[buffer.length - 1] != '\n' &&
        raw.firstOrNull() != '\n'
    ) {
        buffer.append('\n')
    }
    buffer.append(raw)
}

internal fun consumeIncrementalJsonLines(
    text: String,
    onDecodedJson: (JSONObject, String?) -> Unit,
): Boolean {
    if (text.isBlank()) return false
    var currentEvent = ""
    var lastEvent = ""
    var pendingData = ""
    var sawData = false
    var done = false

    fun clearPending() {
        pendingData = ""
    }

    fun fallbackEventName(): String? {
        val ev = if (currentEvent.isNotBlank()) currentEvent else lastEvent
        return ev.ifBlank { null }
    }

    fun ingestDataLine(rawDataLine: String) {
        val dataLine = rawDataLine.trimStart()
        if (dataLine.isBlank() || done) return
        if (dataLine == "[DONE]") {
            clearPending()
            done = true
            return
        }
        sawData = true
        pendingData =
            if (pendingData.isEmpty()) {
                dataLine
            } else {
                pendingData + "\n" + dataLine
            }
        try {
            val obj = JSONObject(pendingData)
            onDecodedJson(obj, fallbackEventName())
            clearPending()
        } catch (_: Exception) {
        }
    }

    val normalized = text.replace("\r\n", "\n").replace('\r', '\n')
    for (rawLine0 in normalized.split('\n')) {
        if (done) break
        val line = rawLine0.trimEnd()
        if (line.isEmpty()) {
            clearPending()
            currentEvent = ""
            continue
        }
        when {
            line.startsWith("event:") -> {
                currentEvent = line.substring(6).trim()
                if (currentEvent.isNotBlank()) {
                    lastEvent = currentEvent
                }
            }
            line.startsWith("id:") ||
                line.startsWith("retry:") ||
                line.startsWith(":") -> {
                continue
            }
            line.startsWith("data:") -> ingestDataLine(line.substring(5))
            else -> ingestDataLine(line)
        }
    }

    if (!done && pendingData.isNotEmpty()) {
        try {
            val obj = JSONObject(pendingData)
            onDecodedJson(obj, fallbackEventName())
        } catch (_: Exception) {
        }
    }
    return sawData
}

internal data class OpenAiCompatibleIncrementalParseResult(
    val content: String,
    val reasoning: String,
    val sawData: Boolean,
    val decodedEvents: Int,
    val payloadError: String?,
)

internal data class OpenAiCompatibleStreamReadResult(
    val body: String,
    val sawData: Boolean,
    val firstEventTimedOut: Boolean,
)

internal fun isOpenAiCompatibleDataLine(rawLine: String): Boolean {
    val line = rawLine.trimEnd()
    if (line.isEmpty()) return false
    if (line.startsWith("event:")) return false
    if (
        line.startsWith("id:") ||
        line.startsWith("retry:") ||
        line.startsWith(":")
    ) {
        return false
    }
    if (line.startsWith("data:")) {
        val dataLine = line.substring(5).trimStart()
        return dataLine.isNotBlank() && dataLine != "[DONE]"
    }
    return true
}

internal fun readOpenAiCompatibleStreamBody(
    ctx: Context,
    stageScope: String?,
    segmentId: Long,
    responseBody: okhttp3.ResponseBody,
    requestTimeoutMs: Long?,
    onDataEvent: ((Long) -> Unit)? = null,
    onPreviewChunk: ((String) -> Unit)? = null,
): OpenAiCompatibleStreamReadResult {
    val rawBody = StringBuilder()
    val previewBuffer = StringBuilder()
    val source = responseBody.source()
    val sourceTimeout = source.timeout()
    sourceTimeout.timeout(
        SegmentSummaryManager.DYNAMIC_AI_STREAM_FIRST_EVENT_TIMEOUT_MS,
        java.util.concurrent.TimeUnit.MILLISECONDS,
    )
    var sawData = false

    fun switchToRegularTimeout() {
        if (requestTimeoutMs != null && requestTimeoutMs > 0L) {
            sourceTimeout.timeout(
                requestTimeoutMs,
                java.util.concurrent.TimeUnit.MILLISECONDS,
            )
        } else {
            sourceTimeout.clearTimeout()
        }
    }

    fun noteDataEvent() {
        val now = System.currentTimeMillis()
        if (!sawData) {
            sawData = true
            switchToRegularTimeout()
        }
        onDataEvent?.invoke(now)
    }

    return try {
        var currentEventName: String? = null
        while (true) {
            SegmentSummaryManager.maybeThrowDynamicAiCancelled(ctx, stageScope, segmentId)
            val rawLine = source.readUtf8Line() ?: break
            rawBody.append(rawLine).append('\n')
            val trimmedLine = rawLine.trimEnd()
            if (trimmedLine.isEmpty()) {
                currentEventName = null
                continue
            }
            if (trimmedLine.startsWith("event:")) {
                currentEventName = trimmedLine.substringAfter(':', "").trim()
                    .let { if (it.isEmpty()) null else it }
                continue
            }
            if (isOpenAiCompatibleDataLine(rawLine)) {
                noteDataEvent()
                extractReadablePreviewFromOpenAiStreamLine(
                    rawLine = rawLine,
                    eventName = currentEventName,
                )?.let { (previewText, forceFlush) ->
                    appendDynamicAiStreamPreviewChunk(
                        buffer = previewBuffer,
                        rawChunk = previewText,
                        forceFlush = forceFlush,
                        emit = { preview -> onPreviewChunk?.invoke(preview) },
                    )
                }
            }
        }
        flushDynamicAiStreamPreviewBuffer(previewBuffer) { preview ->
            onPreviewChunk?.invoke(preview)
        }
        OpenAiCompatibleStreamReadResult(
            body = rawBody.toString(),
            sawData = sawData,
            firstEventTimedOut = false,
        )
    } catch (e: java.net.SocketTimeoutException) {
        if (!sawData) {
            OpenAiCompatibleStreamReadResult(
                body = rawBody.toString(),
                sawData = false,
                firstEventTimedOut = true,
            )
        } else {
            throw e
        }
    } catch (e: java.io.InterruptedIOException) {
        val timeoutLike =
            (e.message ?: "").contains("timeout", ignoreCase = true)
        if (!sawData && timeoutLike) {
            OpenAiCompatibleStreamReadResult(
                body = rawBody.toString(),
                sawData = false,
                firstEventTimedOut = true,
            )
        } else {
            throw e
        }
    }
}

internal fun extractReadablePreviewFromOpenAiStreamLine(
    rawLine: String,
    eventName: String?,
): Pair<String, Boolean>? {
    val trimmedLine = rawLine.trim()
    if (trimmedLine.isEmpty()) return null
    val payload = when {
        trimmedLine.startsWith("data:") -> trimmedLine.substring(5).trim()
        trimmedLine.startsWith("id:") ||
            trimmedLine.startsWith("retry:") ||
            trimmedLine.startsWith(":") -> return null
        else -> trimmedLine
    }
    if (payload.isEmpty() || payload == "[DONE]") return null
    return try {
        val obj = JSONObject(payload)
        val eventType = pickNonEmpty(obj.optString("type"), eventName ?: "")
        val aggregated = StringBuilder()
        val aggregatedReasoning = StringBuilder()
        collectTextFromOpenAiCompatibleStreamJson(
            obj = obj,
            aggregated = aggregated,
            aggregatedReasoning = aggregatedReasoning,
            eventName = eventName,
        )
        val preview = pickNonEmpty(
            aggregated.toString(),
            aggregatedReasoning.toString(),
            obj.optString("delta"),
            obj.optString("text"),
        )
        val normalizedPreview = normalizeDynamicAiStreamPreviewText(preview)
        if (normalizedPreview.isBlank()) {
            null
        } else {
            normalizedPreview to
                (eventType.endsWith(".done") || eventType == "response.completed")
        }
    } catch (_: Exception) {
        null
    }
}

internal fun appendDynamicAiStreamPreviewChunk(
    buffer: StringBuilder,
    rawChunk: String,
    forceFlush: Boolean = false,
    emit: (String) -> Unit,
) {
    val normalized = normalizeDynamicAiStreamPreviewText(rawChunk)
    if (normalized.isBlank()) return
    if (buffer.isNotEmpty() && shouldInsertSpaceBetweenPreviewChunks(buffer.last(), normalized.first())) {
        buffer.append(' ')
    }
    buffer.append(normalized)
    if (forceFlush || shouldFlushDynamicAiStreamPreview(normalized, buffer.length)) {
        flushDynamicAiStreamPreviewBuffer(buffer, emit)
    }
}

internal fun flushDynamicAiStreamPreviewBuffer(
    buffer: StringBuilder,
    emit: (String) -> Unit,
) {
    val normalized = normalizeDynamicAiStreamPreviewText(buffer.toString())
    buffer.setLength(0)
    if (normalized.isBlank()) return
    emit(normalized)
}

internal fun normalizeDynamicAiStreamPreviewText(text: String): String {
    val collapsed = text.replace(Regex("\\s+"), " ").trim()
    if (collapsed.isEmpty()) return ""
    return truncateForLog(collapsed, SegmentSummaryManager.DYNAMIC_AI_STREAM_PREVIEW_MAX_LEN)
}

internal fun shouldFlushDynamicAiStreamPreview(
    chunk: String,
    totalLength: Int,
): Boolean {
    if (totalLength >= SegmentSummaryManager.DYNAMIC_AI_STREAM_PREVIEW_FLUSH_LEN) return true
    return when (chunk.lastOrNull()) {
        '。', '！', '？', '；', '.', '!', '?', ';' -> true
        else -> false
    }
}

internal fun shouldInsertSpaceBetweenPreviewChunks(
    previous: Char,
    next: Char,
): Boolean {
    return previous.isLetterOrDigit() &&
        next.isLetterOrDigit() &&
        !previous.isWhitespace() &&
        !next.isWhitespace()
}

internal fun parseOpenAiCompatibleIncrementalBody(
    body: String,
): OpenAiCompatibleIncrementalParseResult {
    if (body.isBlank()) {
        return OpenAiCompatibleIncrementalParseResult(
            content = "",
            reasoning = "",
            sawData = false,
            decodedEvents = 0,
            payloadError = null,
        )
    }
    val aggregated = StringBuilder()
    val aggregatedReasoning = StringBuilder()
    var payloadError: String? = null
    var decodedEvents = 0
    val sawData = consumeIncrementalJsonLines(body) { obj, eventName ->
        val err = pickNonEmpty(
            obj.optJSONObject("error")?.toString(),
            obj.optString("error"),
        )
        if (err.isNotBlank()) {
            payloadError = err
            return@consumeIncrementalJsonLines
        }
        decodedEvents += 1
        collectTextFromOpenAiCompatibleStreamJson(
            obj = obj,
            aggregated = aggregated,
            aggregatedReasoning = aggregatedReasoning,
            eventName = eventName,
        )
    }
    return OpenAiCompatibleIncrementalParseResult(
        content = aggregated.toString(),
        reasoning = aggregatedReasoning.toString(),
        sawData = sawData,
        decodedEvents = decodedEvents,
        payloadError = payloadError,
    )
}

internal fun collectTextFromOpenAiCompatibleStreamJson(
    obj: JSONObject,
    aggregated: StringBuilder,
    aggregatedReasoning: StringBuilder,
    eventName: String? = null,
) {
    val eventType = pickNonEmpty(
        obj.optString("type"),
        eventName ?: "",
    )
    if (eventType.isNotBlank()) {
        when (eventType) {
            "response.output_text.delta" -> {
                val deltaText = obj.optString("delta")
                if (deltaText.isNotBlank()) {
                    aggregated.append(deltaText)
                }
            }
            "response.output_text.done" -> {
                reconcileTerminalContent(
                    aggregated,
                    obj.optString("text"),
                )
            }
            "response.content_part.done" -> {
                val part = obj.optJSONObject("part")
                if (part != null) {
                    val partType = part.optString("type")
                    if (partType == "output_text" || partType == "text") {
                        reconcileTerminalContent(
                            aggregated,
                            extractTextFromContentNode(part),
                        )
                    }
                }
            }
            "response.output_item.done" -> {
                val item = obj.optJSONObject("item")
                if (item != null && item.optString("type") == "message") {
                    reconcileTerminalContent(
                        aggregated,
                        extractTextFromContentNode(item.opt("content")),
                    )
                }
            }
            "response.completed" -> {
                val responseObj = obj.optJSONObject("response")
                if (responseObj != null) {
                    reconcileTerminalContent(
                        aggregated,
                        extractTextFromResponsesOutput(
                            responseObj.optJSONArray("output"),
                        ),
                    )
                }
            }
            "response.reasoning_text.delta",
            "response.reasoning_summary_text.delta" -> {
                appendReasoningPiece(
                    aggregatedReasoning,
                    obj.optString("delta"),
                )
            }
            "response.reasoning_text.done",
            "response.reasoning_summary_text.done" -> {
                appendReasoningPiece(
                    aggregatedReasoning,
                    obj.optString("text"),
                )
            }
        }
    }

    val choices = obj.optJSONArray("choices")
    if (choices != null && choices.length() > 0) {
        val c0 = choices.optJSONObject(0)
        if (c0 != null) {
            val delta = c0.optJSONObject("delta")
            if (delta != null) {
                val piece = extractTextFromContentNode(
                    delta.opt("content"),
                )
                if (piece.isNotBlank()) {
                    aggregated.append(piece)
                }

                val reasoningPiece = pickNonEmpty(
                    delta.optString("reasoning_content"),
                    delta.optString("reasoning"),
                    extractTextFromContentNode(delta.opt("reasoning")),
                    delta.optString("thinking"),
                )
                appendReasoningPiece(
                    aggregatedReasoning,
                    reasoningPiece,
                )
            }

            val doneMessage = c0.optJSONObject("message")
            if (doneMessage != null) {
                reconcileTerminalContent(
                    aggregated,
                    extractTextFromContentNode(doneMessage.opt("content")),
                )
            }
        }
    }

    val outputText = obj.optString("output_text")
    if (outputText.isNotBlank()) {
        reconcileTerminalContent(aggregated, outputText)
    }
    val responsesText = extractTextFromResponsesOutput(obj.optJSONArray("output"))
    if (responsesText.isNotBlank()) {
        reconcileTerminalContent(aggregated, responsesText)
    }
}

internal fun extractTextFromIncrementalStreamBody(body: String): String {
    if (body.isBlank()) return ""
    val parsed = parseOpenAiCompatibleIncrementalBody(body)
    if (parsed.content.isNotBlank()) {
        return parsed.content
    }
    val aggregated = StringBuilder()
    var lastGoogleCumulative = ""
    consumeIncrementalJsonLines(body) { obj, _ ->
        if (obj.has("error")) return@consumeIncrementalJsonLines

        val googleChunk = extractTextFromGoogleCandidates(obj.optJSONArray("candidates"))
        if (googleChunk.isBlank()) return@consumeIncrementalJsonLines

        val delta =
            if (googleChunk.startsWith(lastGoogleCumulative)) {
                googleChunk.substring(lastGoogleCumulative.length)
            } else {
                googleChunk
            }
        if (delta.isNotBlank()) {
            aggregated.append(delta)
        }
        lastGoogleCumulative =
            if (googleChunk.startsWith(lastGoogleCumulative)) {
                googleChunk
            } else {
                lastGoogleCumulative + googleChunk
            }
    }
    return aggregated.toString()
}

internal fun extractTextFromContentNode(node: Any?): String {
    return when (node) {
        null -> ""
        is String -> node
        is JSONObject -> {
            val direct = node.optString("text")
            if (direct.isNotBlank()) {
                direct
            } else {
                pickNonEmpty(
                    extractTextFromContentNode(node.opt("content")),
                    extractTextFromContentNode(node.opt("parts")),
                )
            }
        }
        is JSONArray -> {
            val out = StringBuilder()
            for (i in 0 until node.length()) {
                val t = extractTextFromContentNode(node.opt(i))
                if (t.isNotEmpty()) out.append(t)
            }
            out.toString()
        }
        else -> ""
    }
}

internal fun normalizeOpenAiCompatiblePath(path: String?): String {
    val trimmed = path?.trim().orEmpty()
    if (trimmed.isEmpty()) return "/v1/chat/completions"
    return if (trimmed.startsWith('/')) trimmed else "/$trimmed"
}

internal fun buildGeminiUrl(base: String, model: String, stream: Boolean): String {
    return if (stream) {
        "$base/v1beta/models/$model:streamGenerateContent?alt=sse"
    } else {
        "$base/v1beta/models/$model:generateContent"
    }
}

internal fun isResponsesPath(path: String?): Boolean {
    val normalized = path?.trim()?.lowercase().orEmpty()
    if (normalized.isEmpty()) return false
    return normalized.endsWith("/responses") ||
        normalized.contains("/responses?") ||
        normalized == "responses"
}

internal fun buildOpenAiCompatibleUrl(base: String, chatPath: String?): String {
    return base + normalizeOpenAiCompatiblePath(chatPath)
}

internal fun buildResponsesUrl(base: String, chatPath: String?): String {
    val normalized = normalizeOpenAiCompatiblePath(chatPath)
    if (isResponsesPath(normalized)) {
        return base + normalized
    }
    val chatCompletions = Regex(
        "/chat/completions(?:$|\\?)",
        setOf(RegexOption.IGNORE_CASE),
    )
    if (chatCompletions.containsMatchIn(normalized)) {
        return base + normalized.replaceFirst(chatCompletions, "/responses")
    }
    val lastSlash = normalized.lastIndexOf('/')
    val prefix = if (lastSlash >= 0) normalized.substring(0, lastSlash) else ""
    val versionPrefix =
        if (prefix.lowercase().endsWith("/v1")) prefix else "/v1"
    return base + "$versionPrefix/responses"
}

internal fun shouldPreferResponsesApi(chatPath: String?): Boolean {
    return isResponsesPath(chatPath)
}

internal fun shouldAllowResponsesFallback(chatPath: String?): Boolean {
    return isResponsesPath(chatPath)
}

internal fun extractTextFromOpenAiChoices(choices: JSONArray?): String {
    if (choices == null || choices.length() == 0) return ""
    val out = StringBuilder()
    for (i in 0 until choices.length()) {
        val choice = choices.optJSONObject(i) ?: continue
        val message = choice.optJSONObject("message")
        val delta = choice.optJSONObject("delta")
        val piece = pickNonEmpty(
            extractTextFromContentNode(message?.opt("content")),
            extractTextFromContentNode(delta?.opt("content")),
            delta?.optString("text"),
            extractTextFromContentNode(choice.opt("content")),
            choice.optString("text"),
        )
        if (piece.isNotEmpty()) out.append(piece)
    }
    return out.toString()
}

internal fun extractTextFromGoogleCandidates(candidates: JSONArray?): String {
    if (candidates == null || candidates.length() == 0) return ""
    val out = StringBuilder()
    for (i in 0 until candidates.length()) {
        val candidate = candidates.optJSONObject(i) ?: continue
        val content = candidate.optJSONObject("content") ?: continue
        val parts = content.optJSONArray("parts") ?: continue
        for (j in 0 until parts.length()) {
            val part = parts.optJSONObject(j) ?: continue
            if (part.optBoolean("thought", false)) continue
            val text = part.optString("text")
            if (text.isNotBlank()) out.append(text)
        }
    }
    return out.toString()
}

internal fun extractTextFromOpenAiCompatibleBody(body: String): String {
    if (body.isBlank()) return ""
    return try {
        val obj = JSONObject(body)
        val direct = extractTextFromOpenAiCompatibleJsonObject(obj)
        val incremental = extractTextFromIncrementalStreamBody(body)
        when {
            incremental.length > direct.length -> incremental
            direct.isNotBlank() -> direct
            else -> incremental
        }
    } catch (_: Exception) {
        try {
            val arr = JSONArray(body)
            val out = StringBuilder()
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                val piece = extractTextFromOpenAiCompatibleJsonObject(item)
                if (piece.isNotBlank()) out.append(piece)
            }
            val direct = out.toString()
            val incremental = extractTextFromIncrementalStreamBody(body)
            when {
                incremental.length > direct.length -> incremental
                direct.isNotBlank() -> direct
                else -> incremental
            }
        } catch (_: Exception) {
            extractTextFromIncrementalStreamBody(body)
        }
    }
}

internal fun extractTextFromOpenAiCompatibleJsonObject(obj: JSONObject): String {
    return pickNonEmpty(
        obj.optString("output_text"),
        extractTextFromResponsesOutput(obj.optJSONArray("output")),
        extractTextFromOpenAiChoices(obj.optJSONArray("choices")),
        extractTextFromGoogleCandidates(obj.optJSONArray("candidates")),
    )
}

internal fun extractTextFromGeminiBody(body: String): String {
    if (body.isBlank()) return ""
    return try {
        val obj = JSONObject(body)
        val direct = pickNonEmpty(
            extractTextFromGoogleCandidates(obj.optJSONArray("candidates")),
            extractTextFromOpenAiChoices(obj.optJSONArray("choices")),
            obj.optString("text"),
        )
        val incremental = extractTextFromIncrementalStreamBody(body)
        when {
            incremental.length > direct.length -> incremental
            direct.isNotBlank() -> direct
            else -> incremental
        }
    } catch (_: Exception) {
        extractTextFromOpenAiCompatibleBody(body)
    }
}

internal fun extractTextFromResponsesOutput(output: JSONArray?): String {
    if (output == null || output.length() == 0) return ""
    val out = StringBuilder()
    for (i in 0 until output.length()) {
        val item = output.optJSONObject(i) ?: continue
        when (item.optString("type")) {
            "message" -> {
                val text = extractTextFromContentNode(item.opt("content"))
                if (text.isNotEmpty()) out.append(text)
            }
            "output_text", "text" -> {
                val text = item.optString("text")
                if (text.isNotEmpty()) out.append(text)
            }
        }
    }
    return out.toString()
}

internal fun reconcileTerminalContent(buffer: StringBuilder, fullCandidate: String?) {
    val full = fullCandidate ?: ""
    if (full.trim().isEmpty()) return
    val current = buffer.toString()
    if (current.isEmpty()) {
        buffer.append(full)
        return
    }
    if (full.startsWith(current)) {
        buffer.setLength(0)
        buffer.append(full)
        return
    }
    if (current.startsWith(full)) {
        return
    }
    if (full.length > current.length) {
        buffer.setLength(0)
        buffer.append(full)
    }
}
