package com.fqyw.screen_memo.segment

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import com.fqyw.screen_memo.database.SegmentDatabaseHelper
import com.fqyw.screen_memo.logging.FileLogger
import com.fqyw.screen_memo.logging.OutputFileLogger
import com.fqyw.screen_memo.network.OkHttpClientFactory
import com.fqyw.screen_memo.settings.AISettingsNative
import com.fqyw.screen_memo.settings.UserSettingsKeysNative
import com.fqyw.screen_memo.settings.UserSettingsStorage
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Timer
import java.util.TimerTask
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "SegmentSummaryManager"
    internal data class AiCallResult(
        val model: String,
        val outputText: String,
        val structuredJson: String?,
        val categories: String?,
        val rawRequest: String?,
        val rawResponse: String?
    )

internal fun buildDynamicProbeToken(): String {
        val random = java.util.UUID.randomUUID().toString().replace("-", "")
        val stamp = java.lang.Long.toString(System.nanoTime(), 36)
        return "probe_${random}_${stamp}"
    }

internal fun probeResponseHasContent(response: String): Boolean {
        return response.trim().isNotEmpty()
    }

internal fun SegmentSummaryManager.executeDynamicProbeRequest(
        ctx: Context,
        cfg: AISettingsNative.AIConfig,
        token: String,
        timeoutMs: Long,
    ): String {
        maybeThrowDynamicAiCancelled(ctx, DYNAMIC_AI_STAGE_SUMMARY, 0L)
        val client = OkHttpClientFactory.newBuilder(ctx)
            .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
            .callTimeout(timeoutMs.coerceAtLeast(1_000L), java.util.concurrent.TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMs.coerceAtLeast(1_000L), java.util.concurrent.TimeUnit.MILLISECONDS)
            .writeTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()

        val base = cfg.baseUrl.trimEnd('/')
        val model = cfg.model.trim()
        val systemPrompt =
            "Reply with exactly the requested substring. No markdown. No explanation. No punctuation."
        val userPrompt =
            "Return only the last 12 characters of this random string. Do not add punctuation or explanation.\n$token"
        val isGoogle = isGoogleAiConfig(cfg)
        val body: String
        val requestBuilder = Request.Builder()
            .addHeader("Content-Type", "application/json")
            .addHeader("Accept", "application/json")

        if (isGoogle) {
            val parts = JSONArray()
                .put(JSONObject().put("text", "$systemPrompt\n\n$userPrompt"))
            val contents = JSONArray().put(JSONObject().put("parts", parts))
            body = JSONObject()
                .put("contents", contents)
                .toString()
            requestBuilder
                .url(buildGeminiUrl(base, model, stream = false))
                .addHeader("x-goog-api-key", cfg.apiKey)
        } else {
            val normalizedChatPath = normalizeOpenAiCompatiblePath(cfg.chatPath)
            val preferResponsesApi = shouldPreferResponsesApi(normalizedChatPath)
            if (preferResponsesApi) {
                val input = JSONArray()
                    .put(
                        JSONObject()
                            .put("role", "system")
                            .put(
                                "content",
                                JSONArray().put(
                                    JSONObject()
                                        .put("type", "input_text")
                                        .put("text", systemPrompt),
                                ),
                            ),
                    )
                    .put(
                        JSONObject()
                            .put("role", "user")
                            .put(
                                "content",
                                JSONArray().put(
                                    JSONObject()
                                        .put("type", "input_text")
                                        .put("text", userPrompt),
                                ),
                            ),
                    )
                body = JSONObject()
                    .put("model", model)
                    .put("input", input)
                    .put("stream", false)
                    .toString()
                requestBuilder.url(buildResponsesUrl(base, normalizedChatPath))
            } else {
                val messages = JSONArray()
                    .put(JSONObject().put("role", "system").put("content", systemPrompt))
                    .put(JSONObject().put("role", "user").put("content", userPrompt))
                body = JSONObject()
                    .put("model", model)
                    .put("messages", messages)
                    .put("stream", false)
                    .toString()
                requestBuilder.url(buildOpenAiCompatibleUrl(base, normalizedChatPath))
            }
            requestBuilder.addHeader("Authorization", "Bearer ${cfg.apiKey}")
        }

        val reqBody = body.toRequestBody("application/json; charset=utf-8".toMediaType())
        val request = requestBuilder.post(reqBody).build()
        return executeTrackedCall(
            ctx = ctx,
            stageScope = DYNAMIC_AI_STAGE_SUMMARY,
            segmentId = 0L,
            call = client.newCall(request),
        ) { resp ->
            val responseBody = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                throw IllegalStateException("Request failed: ${resp.code} $responseBody")
            }
            val text = if (isGoogle) {
                extractTextFromGeminiBody(responseBody)
            } else {
                extractTextFromOpenAiCompatibleBody(responseBody)
            }
            text
        }
    }

    private fun extractAiFailureSnippet(rawResponse: String, maxLen: Int = 240): String {
        val normalized = rawResponse
            .replace("\r", " ")
            .replace("\n", " ")
            .replace(Regex("\\s+"), " ")
            .trim()
        if (normalized.isEmpty()) return ""
        val patterns = listOf(
            Regex("\"message\"\\s*:\\s*\"([^\"]+)\"", RegexOption.IGNORE_CASE),
            Regex("\"error\"\\s*:\\s*\"([^\"]+)\"", RegexOption.IGNORE_CASE),
            Regex("\"detail\"\\s*:\\s*\"([^\"]+)\"", RegexOption.IGNORE_CASE),
        )
        for (pattern in patterns) {
            val matched = pattern.find(normalized)?.groupValues?.getOrNull(1)?.trim()
            if (!matched.isNullOrEmpty()) {
                return truncateForLog(matched, maxLen)
            }
        }
        return truncateForLog(normalized, maxLen)
    }

    private fun looksLikeOpenAiCompatibleEmptyChoicesResponse(rawResponse: String): Boolean {
        if (rawResponse.isBlank()) return false
        val hasEmptyChoices =
            Regex("\"choices\"\\s*:\\s*\\[\\s*\\]", RegexOption.IGNORE_CASE)
                .containsMatchIn(rawResponse)
        if (!hasEmptyChoices) return false
        val hasZeroCompletion =
            Regex("\"completion_tokens\"\\s*:\\s*0", RegexOption.IGNORE_CASE)
                .containsMatchIn(rawResponse)
        val hasZeroOutput =
            Regex("\"output_tokens\"\\s*:\\s*0", RegexOption.IGNORE_CASE)
                .containsMatchIn(rawResponse)
        return hasZeroCompletion || hasZeroOutput
    }

    internal fun buildAiPayloadFailureMessage(providerLabel: String, rawResponse: String): String {
        if (looksLikeOpenAiCompatibleEmptyChoicesResponse(rawResponse)) {
            return "AI 返回空 choices(${providerLabel})：HTTP 200 但 provider 未生成正文（choices 为空、completion_tokens=0；常见于提示过大、安全过滤或中继兼容性问题）"
        }
        val snippet = extractAiFailureSnippet(rawResponse)
        return if (snippet.isNotEmpty()) {
            "AI 返回错误响应(${providerLabel})：$snippet"
        } else {
            "AI 返回空响应或异常响应(${providerLabel})"
        }
    }

    private fun isOfficialGeminiBase(baseUrl: String?): Boolean {
        val normalized = baseUrl?.trim()?.lowercase().orEmpty()
        if (normalized.isEmpty()) return false
        return normalized.contains("googleapis.com") ||
            normalized.contains("generativelanguage")
    }

    private fun isGoogleAiConfig(cfg: AISettingsNative.AIConfig?): Boolean {
        if (cfg == null) return false
        val providerType = cfg.providerType?.trim()?.lowercase().orEmpty()
        return providerType == "gemini" || isOfficialGeminiBase(cfg.baseUrl)
    }

    internal fun shouldUseSlimOpenAiMergePrompt(cfg: AISettingsNative.AIConfig?): Boolean {
        return !isGoogleAiConfig(cfg)
    }

    private fun buildAiTerminalFailureMessage(
        lastFailureKind: String?,
        lastFailure: Throwable?,
        maxAttempts: Int,
        requestTimeoutMs: Long? = null,
    ): String {
        val message = lastFailure?.message?.trim().orEmpty()
        return when (lastFailureKind) {
            "timeout" -> {
                val timeoutHint =
                    if (requestTimeoutMs != null && requestTimeoutMs > 0L) {
                        "（单次请求上限 ${requestTimeoutMs / 60000L} 分钟）"
                    } else {
                        ""
                    }
                "AI 请求超时${timeoutHint}，已重试 ${maxAttempts} 次；请检查网络或模型服务后手动继续"
            }
            "interrupted" ->
                if (message.isNotEmpty()) {
                    "AI 请求已中断：$message"
                } else {
                    "AI 请求已中断，请检查网络后手动继续"
                }
            "exception" ->
                if (message.isNotEmpty()) {
                    "AI 请求异常（已重试 ${maxAttempts} 次）：$message"
                } else {
                    "AI 请求异常（已重试 ${maxAttempts} 次）"
                }
            else ->
                if (message.isNotEmpty()) {
                    "AI 请求失败：$message"
                } else {
                    "AI 请求失败：未知错误"
                }
        }
    }

internal fun classifyAiFailure(message: String): String {
        val msg = message.lowercase()
        return when {
            msg.contains("401") || msg.contains("403") -> "auth_failed"
            msg.contains("model_not_found") || msg.contains("unsupported_model") -> "model_not_found"
            msg.contains("does not exist") && msg.contains("model") -> "model_not_found"
            msg.contains("not found") && msg.contains("model") -> "model_not_found"
            msg.contains("429") || msg.contains("408") || msg.contains("timeout") ||
                msg.contains("socket") || msg.contains("connection") || msg.contains("network") ||
                msg.contains("500") || msg.contains("502") || msg.contains("503") || msg.contains("504") -> "retryable"
            else -> "fatal"
        }
    }

    private fun shouldTryNextProviderKey(errorType: String): Boolean {
        return errorType == "auth_failed" || errorType == "model_not_found" || errorType == "retryable"
    }

internal fun SegmentSummaryManager.resolveAiConfigCandidates(
        ctx: Context,
        aiConfigOverride: AISettingsNative.AIConfig?,
    ): List<AISettingsNative.AIConfig> {
        if (aiConfigOverride == null) {
            return try { AISettingsNative.readConfigCandidates(ctx, "segments") } catch (_: Exception) { listOf(AISettingsNative.readConfig(ctx)) }
        }
        // 如果传入配置没有绑定 provider key，则重新展开候选 key，避免动态重建沿用快照后无法切换 key。
        if (aiConfigOverride.providerKeyId != null) return listOf(aiConfigOverride)
        val candidates = try { AISettingsNative.readConfigCandidates(ctx, "segments") } catch (_: Exception) { emptyList() }
        if (candidates.isEmpty()) return listOf(aiConfigOverride)
        val filtered = candidates.filter { cfg ->
            cfg.model.trim().equals(aiConfigOverride.model.trim(), ignoreCase = true) &&
                (aiConfigOverride.providerId == null || cfg.providerId == aiConfigOverride.providerId)
        }
        return if (filtered.isNotEmpty()) filtered else listOf(aiConfigOverride)
    }

    // 返回结果 (model, outputText, structuredJson, categories, rawRequest, rawResponse)
    internal fun SegmentSummaryManager.callGeminiWithImages(
        ctx: Context,
        seg: SegmentDatabaseHelper.Segment,
        samples: List<SegmentDatabaseHelper.Sample>,
        prompt: String,
        isMerge: Boolean = false,
        injectDynamicRules: Boolean = true,
        maxImagesOverride: Int? = null,
        allowJsonAutoRetry: Boolean = true,
        jsonRetryCount: Int = 0,
        aiConfigOverride: AISettingsNative.AIConfig? = null,
        strictFailure: Boolean = false,
        stageReporter: ((String, String, String, Long) -> Unit)? = null,
        stageScope: String? = null,
    ): AiCallResult {
        val configs = resolveAiConfigCandidates(ctx, aiConfigOverride)
        val diagEnabled = isDynamicAiStage(stageScope) || isDynamicRebuildTaskActive(ctx)
        if (diagEnabled) {
            logBackfillDiag(
                ctx,
                "aiCall enter seg=${seg.id} samples=${samples.size} promptLen=${prompt.length} " +
                    "isMerge=$isMerge injectDynamicRules=$injectDynamicRules maxImagesOverride=${maxImagesOverride ?: "null"} " +
                    "allowJsonAutoRetry=$allowJsonAutoRetry jsonRetryCount=$jsonRetryCount strictFailure=$strictFailure " +
                    "stageScope=${stageScope ?: "null"} configCount=${configs.size} override=${aiConfigOverride != null}",
            )
        }
        var lastError: Exception? = null
        for ((index, cfg) in configs.withIndex()) {
            try {
                if (diagEnabled) {
                    logBackfillDiag(
                        ctx,
                        "aiCall candidateStart seg=${seg.id} candidate=${index + 1}/${configs.size} " +
                            "keyId=${cfg.providerKeyId ?: 0} keyName=${cfg.providerKeyName ?: "legacy"} " +
                            "providerId=${cfg.providerId ?: 0} providerType=${cfg.providerType ?: "unknown"} " +
                            "model=${cfg.model} baseUrl=${cfg.baseUrl} chatPath=${cfg.chatPath ?: "default"}",
                    )
                }
                if (configs.size > 1) {
                    FileLogger.i(
                        TAG,
                        "AI key candidate ${index + 1}/${configs.size}: key_id=${cfg.providerKeyId ?: 0} key_name=${cfg.providerKeyName ?: "legacy"} model=${cfg.model} seg=${seg.id}"
                    )
                }
                val result = callGeminiWithImagesSingleKey(
                    ctx = ctx,
                    seg = seg,
                    samples = samples,
                    prompt = prompt,
                    isMerge = isMerge,
                    injectDynamicRules = injectDynamicRules,
                    maxImagesOverride = maxImagesOverride,
                    allowJsonAutoRetry = allowJsonAutoRetry,
                    jsonRetryCount = jsonRetryCount,
                    aiConfigOverride = cfg,
                    strictFailure = strictFailure,
                    stageReporter = stageReporter,
                    stageScope = stageScope,
                )
                if (diagEnabled) {
                    logBackfillDiag(
                        ctx,
                        "aiCall candidateSuccess seg=${seg.id} candidate=${index + 1}/${configs.size} " +
                            "keyId=${cfg.providerKeyId ?: 0} model=${result.model} outputLen=${result.outputText.length} " +
                            "structuredLen=${result.structuredJson?.length ?: 0}",
                    )
                }
                AISettingsNative.markProviderKeySuccess(ctx, cfg)
                return result
            } catch (e: Exception) {
                lastError = e
                val msg = e.message ?: e.toString()
                val errorType = classifyAiFailure(msg)
                if (diagEnabled) {
                    logBackfillDiag(
                        ctx,
                        "aiCall candidateFailed seg=${seg.id} candidate=${index + 1}/${configs.size} " +
                            "keyId=${cfg.providerKeyId ?: 0} type=$errorType message=${truncateForLog(msg, 500)}",
                    )
                }
                AISettingsNative.markProviderKeyFailure(ctx, cfg.providerKeyId, errorType, msg, 3)
                if (configs.size > 1) {
                    FileLogger.w(
                        TAG,
                        "AI key candidate failed: key_id=${cfg.providerKeyId ?: 0} type=$errorType candidate=${index + 1}/${configs.size} seg=${seg.id} message=${truncateForLog(msg, 500)}"
                    )
                }
                if (!shouldTryNextProviderKey(errorType) || index == configs.lastIndex) {
                    throw e
                }
            }
        }
        throw lastError ?: IllegalStateException("No AI config available")
    }

    private fun SegmentSummaryManager.callGeminiWithImagesSingleKey(
        ctx: Context,
        seg: SegmentDatabaseHelper.Segment,
        samples: List<SegmentDatabaseHelper.Sample>,
        prompt: String,
        isMerge: Boolean = false,
        injectDynamicRules: Boolean = true,
        maxImagesOverride: Int? = null,
        allowJsonAutoRetry: Boolean = true,
        jsonRetryCount: Int = 0,
        aiConfigOverride: AISettingsNative.AIConfig? = null,
        strictFailure: Boolean = false,
        stageReporter: ((String, String, String, Long) -> Unit)? = null,
        stageScope: String? = null,
    ): AiCallResult {
        val diagEnabled = isDynamicAiStage(stageScope) || isDynamicRebuildTaskActive(ctx)
        if (diagEnabled) {
            logBackfillDiag(
                ctx,
                "aiCall singleEnter seg=${seg.id} samples=${samples.size} promptLen=${prompt.length} " +
                    "isMerge=$isMerge injectDynamicRules=$injectDynamicRules maxImagesOverride=${maxImagesOverride ?: "null"} " +
                    "allowJsonAutoRetry=$allowJsonAutoRetry jsonRetryCount=$jsonRetryCount strictFailure=$strictFailure " +
                    "stageScope=${stageScope ?: "null"} override=${aiConfigOverride != null}",
            )
        }
        val cfg = aiConfigOverride ?: AISettingsNative.readConfig(ctx)
        val apiKey = cfg.apiKey
        val requestTimeoutMs = resolveDynamicAiRequestTimeoutMs(stageScope)
        if (diagEnabled) {
            logBackfillDiag(
                ctx,
                "aiCall configResolved seg=${seg.id} providerId=${cfg.providerId ?: 0} " +
                    "providerType=${cfg.providerType ?: "unknown"} keyId=${cfg.providerKeyId ?: 0} " +
                    "keyName=${cfg.providerKeyName ?: "legacy"} model=${cfg.model} baseUrl=${cfg.baseUrl} " +
                    "chatPath=${cfg.chatPath ?: "default"} apiKeyBlank=${apiKey.isBlank()} timeoutMs=${requestTimeoutMs ?: 0L}",
            )
        }
        val clientBuilder = OkHttpClientFactory.newBuilder(ctx)
            .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
        if (requestTimeoutMs != null && requestTimeoutMs > 0L) {
            clientBuilder
                // 不设置 callTimeout：动态流式生成可能持续超过 3 分钟，只按读/写空闲超时中断。
                .readTimeout(requestTimeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
                .writeTimeout(requestTimeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        } else {
            clientBuilder
                .readTimeout(0, java.util.concurrent.TimeUnit.SECONDS)
                .writeTimeout(0, java.util.concurrent.TimeUnit.SECONDS)
        }
        val client = clientBuilder.build()
        if (diagEnabled) {
            logBackfillDiag(ctx, "aiCall clientReady seg=${seg.id} timeoutMs=${requestTimeoutMs ?: 0L}")
        }

        val model = cfg.model
        val base = if (cfg.baseUrl.endsWith('/')) cfg.baseUrl.dropLast(1) else cfg.baseUrl
        val isGoogle = isGoogleAiConfig(cfg)
        val geminiUseStreaming = isOfficialGeminiBase(base)
        val normalizedChatPath = normalizeOpenAiCompatiblePath(cfg.chatPath)
        val preferResponsesApi =
            !isGoogle && shouldPreferResponsesApi(normalizedChatPath)
        val responsesUrl = if (!isGoogle) buildResponsesUrl(base, normalizedChatPath) else ""
        val primaryOpenAiUrl =
            if (preferResponsesApi) responsesUrl else buildOpenAiCompatibleUrl(base, normalizedChatPath)
        val primaryOpenAiLabel =
            if (preferResponsesApi) "/v1/responses" else normalizedChatPath
        val allowResponsesFallback =
            !isGoogle &&
                !preferResponsesApi &&
                shouldAllowResponsesFallback(normalizedChatPath)

        // 统一图片限额（默认：floor(duration/interval)，并受提供方硬上限保护；调用方可指定更小的 cap，但不可突破硬上限）
        val capBySeg = (seg.durationSec / seg.sampleIntervalSec).coerceAtLeast(1)
        val requestedCap = maxImagesOverride?.takeIf { it > 0 } ?: capBySeg
        val effectiveCap =
            kotlin.math.min(requestedCap, PROVIDER_IMAGE_HARD_LIMIT).coerceAtLeast(1)
        val rawSamplesOrdered = samples.sortedBy { it.captureTime }
        val samplesOrdered = rawSamplesOrdered.filterNot { isDamagedImageFile(it.filePath) }
        val damagedImages = rawSamplesOrdered.size - samplesOrdered.size
        val candidateSamples =
            if (samplesOrdered.isNotEmpty()) {
                samplesOrdered
            } else {
                rawSamplesOrdered
            }
        val effSamples =
            if (candidateSamples.size > effectiveCap) {
                evenPick(candidateSamples, effectiveCap)
            } else {
                candidateSamples
            }
        if (diagEnabled) {
            logBackfillDiag(
                ctx,
                "aiCall samplesPrepared seg=${seg.id} raw=${rawSamplesOrdered.size} " +
                    "afterDamageFilter=${samplesOrdered.size} damaged=$damagedImages requestedCap=$requestedCap " +
                    "effectiveCap=$effectiveCap effSamples=${effSamples.size} first=${effSamples.take(6).joinToString("|") { sample -> File(sample.filePath).name }}",
            )
        }

        val promptWithRule = if (!injectDynamicRules) {
            prompt
        } else {
            // 依据应用语言注入动态规则：限制逐图文字描述上限（<= 总图数的 1/3）
            val langOptForRule = try { ctx.getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE).getString("flutter.locale_option", "system") } catch (_: Exception) { "system" }
            val sysLangForRule = try { java.util.Locale.getDefault().language?.lowercase() } catch (_: Exception) { "en" } ?: "en"
            val isZhForRule = (langOptForRule == "zh") || (langOptForRule != "en" && sysLangForRule.startsWith("zh"))
            val effectiveLangForRule = when (langOptForRule) {
                "zh", "en", "ja", "ko" -> langOptForRule
                "system" -> when {
                    sysLangForRule.startsWith("zh") -> "zh"
                    sysLangForRule.startsWith("ja") -> "ja"
                    sysLangForRule.startsWith("ko") -> "ko"
                    else -> "en"
                }
                else -> "en"
            }
            val totalImagesToSend = effSamples.size
            val maxDescImages = (totalImagesToSend / 3)
            val slimOpenAiMergePrompt = isMerge && !isGoogle
            val dynamicCapRule = if (isMerge) {
                if (isZhForRule) {
                    """
- 仅对不超过总图数三分之一的代表性图片进行文字描述（向下取整，允许0张）；其余图片不要逐图描述，请合并进整体总结。
- 如需逐图说明，请使用 described_images[] 列出这些被描述的图片（长度≤上述上限）；每项：{file:"图片序号字符串", ref_time:"HH:mm:ss", app:"应用名", summary:"(Markdown) 单图关键信息与选择理由"}。
- key_actions[].ref_image 必须复用 content_groups[].representative_images 中已选择的图片序号，不得新增超出上限的图片引用。
""".trim()
                } else {
                    """
- Provide textual descriptions for at most one-third of the images (floor; may be 0). Do not narrate the rest image-by-image; integrate them into the summary.
- If you describe any individual images, list them in described_images[] (length <= the cap); each item: {file:"image index string", ref_time:"HH:mm:ss", app:"App", summary:"(Markdown) key info and selection reason"}.
- key_actions[].ref_image MUST reuse image indexes chosen in content_groups[].representative_images and MUST NOT exceed the cap.
""".trim()
                }
            } else {
                if (isZhForRule) {
                    """
- 仅对不超过总图数三分之一的代表性图片进行文字描述（向下取整，允许0张）；其余图片不要逐图描述，请合并进摘要。
- 仅使用 described_images[] 列出这些"被文字描述"的单张图片，数组长度<=上述上限；每项结构：{file:"图片序号字符串", ref_time:"HH:mm:ss", app:"应用名", summary:"(Markdown) 单图关键信息与选择理由"}。
- key_actions[].ref_image 必须复用 described_images[] 中的图片序号，不得新增超出上限的图片引用。
""".trim()
                } else {
                    """
- Provide textual descriptions for at most one-third of the images (floor; may be 0). Do not narrate the rest image-by-image; integrate them into the summary.
- Use described_images[] ONLY to list the individually described images, length <= the cap; each item: {file:"image index string", ref_time:"HH:mm:ss", app:"App", summary:"(Markdown) key info and selection reason for the single image"}.
- key_actions[].ref_image MUST reuse image indexes in described_images[] and MUST NOT exceed the cap.
                    """.trim()
                }
            }
            val dynamicImageRule = if (slimOpenAiMergePrompt) {
                when (effectiveLangForRule) {
                    "zh" -> """
 - 本次输入包含多张图片。请按输入顺序将图片编号为连续序号字符串（从 1 开始），后续所有图片引用都必须使用这些序号字符串。
 - key_actions[].ref_image 与 content_groups[].representative_images 只能引用本次输入的图片序号，不得填写文件名或路径。
 - 不要重新生成 image_tags[] 与 image_descriptions[]；系统会沿用原事件已有的图片标签与图片描述。
 """.trim()
                    "ja" -> """
 - 今回の画像は複数枚あります。入力順に連番の文字列（1 から開始）を使い、後続の画像参照は必ずその番号だけを使ってください。
 - key_actions[].ref_image と content_groups[].representative_images は今回入力した画像番号のみ参照でき、ファイル名やパスは使わないでください。
 - image_tags[] と image_descriptions[] を再生成しないでください。既存イベントの画像タグと画像説明をシステム側で引き継ぎます。
 """.trim()
                    "ko" -> """
 - 이번 요청에는 이미지가 여러 장 있습니다. 입력 순서대로 연속 번호 문자열(1부터 시작)을 사용하고, 이후의 모든 이미지 참조는 반드시 그 번호만 사용하세요.
 - key_actions[].ref_image 와 content_groups[].representative_images 는 이번 입력 이미지 번호만 참조할 수 있으며 파일명이나 경로를 쓰면 안 됩니다.
 - image_tags[] 와 image_descriptions[] 는 다시 생성하지 마세요. 기존 이벤트의 이미지 태그와 설명은 시스템이 이어받습니다.
 """.trim()
                    else -> """
 - This request includes multiple images. Number them by input order as consecutive strings starting at 1, and use only those index strings for any later image references.
 - key_actions[].ref_image and content_groups[].representative_images must reference only the provided image indexes, never filenames or paths.
 - Do not regenerate image_tags[] or image_descriptions[]; the system will carry over image tags and descriptions from the original events.
 """.trim()
                }
            } else when (effectiveLangForRule) {
                "zh" -> """
 - 本次输入包含多张图片。请按输入顺序将图片编号为连续序号字符串（从 1 开始）。必须输出 image_tags[]，长度必须等于实际附带图片数量，且 file 必须填写"图片序号字符串"（例如 "1"），不要填写文件名或路径。tags 必须为中文本地化标签；如涉及成人/裸露/性暗示等，请额外添加英文统一标签 "nsfw"（必须小写）。除 "nsfw" 外不要输出英文标签。
 - 必须输出 image_descriptions[] 覆盖所有图片：每项 {from_file:"图片序号字符串", to_file:"图片序号字符串", description:"至少6句自然语言（尽可能 8-12 句）"}；允许将连续且内容高度一致的图片合并为一段（例如连续聊天截图），用 from_file/to_file 表示范围；确保所有图片序号被覆盖且不重复。
 - 为了便于后续检索/语义搜索：description 必须尽可能详尽、多角度描述画面（场景/界面布局/关键元素/可能的操作与意图/状态变化等），并覆盖尽可能多的可检索关键词/实体（应用/页面/功能/人物/地点/商品/流程等）。不要逐字抄写可见文字，也不要输出“可见文字：...”这类字段。每条 description 末尾必须追加 1 行：`关键词：...`（尽可能多、尽可能具体，可包含同义词/拆词/中英缩写；关键词建议至少 20 个，用 `、` 分隔）。
 - key_actions[].ref_image 必须引用本次输入的图片序号之一（字符串）。
 """.trim()
                "ja" -> """
 - 今回は画像が複数枚あります。入力順に連番の文字列（1 から開始）で番号付けしてください。image_tags[] を必ず出力し、要素数は実際の添付画像数と同じにしてください。file にはファイル名ではなく「画像番号の文字列」（例: "1"）を入れてください。tags は日本語のローカライズタグを使用し、成人/露出/性的示唆などがある場合は英語の統一タグ "nsfw"(小文字) を追加してください。"nsfw" 以外は英語タグを出力しないでください。
 - image_descriptions[] で全画像をカバーしてください。各要素: {from_file:"画像番号文字列", to_file:"画像番号文字列", description:"自然言語で6文以上（可能なら 8-12 文）"}。内容がほぼ同じ連続画像（例: チャットの連続スクショ）は 1 つにまとめ、from_file/to_file で範囲を表現してください。全画像番号が重複なく必ず含まれるようにしてください。
 - 検索しやすくするため、description はできるだけ詳細に多角度で記述し（場面/レイアウト/主要要素/想定される操作や意図/状態変化など）、具体的な固有名詞/キーワード（アプリ/画面/機能/人物/場所/商品/ワークフロー等）をできるだけ多く含めてください。画面上の文字の書き起こしは不要で、`表示文字：...` のような欄も出力しないでください。各 description の末尾に必ず 1 行 `キーワード：...` を追加してください（できるだけ多く、同義語/分割語/略語も可；目安として 20 個以上）。
 - key_actions[].ref_image は今回入力した画像番号のいずれかを参照してください（文字列）。
 """.trim()
                "ko" -> """
 - 이번 요청에는 이미지가 여러 장 있습니다. 입력 순서대로 연속 번호 문자열(1부터 시작)을 사용하세요. image_tags[]를 반드시 출력하고 길이는 실제 첨부 이미지 수와 같아야 합니다. file에는 파일명이 아니라 "이미지 번호 문자열"(예: "1")을 넣으세요. tags는 한국어 로컬라이즈 태그를 사용하세요. 성인/노출/성적 암시 등이 있으면 영어 통일 태그 "nsfw"(소문자)를 추가하세요. "nsfw" 외에는 영어 태그를 출력하지 마세요.
 - image_descriptions[]로 모든 이미지를 커버하세요. 각 항목: {from_file:"이미지 번호 문자열", to_file:"이미지 번호 문자열", description:"자연어 6문장 이상(가능하면 8-12문장)"}. 내용이 거의 동일한 연속 이미지(예: 연속 채팅 캡처)는 1개로 묶고 from_file/to_file로 범위를 표시하세요. 모든 이미지 번호가 중복 없이 반드시 포함되도록 하세요.
 - 검색/시맨틱 검색을 위해 description을 가능한 한 상세하고 다각도로 작성하세요(상황/레이아웃/핵심 요소/가능한 행동·의도/상태 변화 등). 구체적인 키워드/개체(앱/화면/기능/인물/장소/상품/워크플로 등)를 최대한 많이 포함하세요. 화면 글자 전사는 필요 없으며 `보이는 글자：...` 같은 항목도 출력하지 마세요. 각 description 끝에 반드시 1줄 `키워드：...`를 추가하세요(가능한 한 많이, 동의어/분해어/약어 포함 가능; 최소 20개 권장).
 - key_actions[].ref_image는 이번 입력 이미지 번호 중 하나를 참조해야 합니다(문자열).
 """.trim()
                else -> """
 - This request includes multiple images. Number them by input order as consecutive strings starting at 1. You MUST output image_tags[] with exactly one item per attached image, and each item's file MUST be an image index string (e.g., "1"), not a filename/path. tags must be localized to the prompt language; if the image contains adult/nudity/sexual content, add the unified English tag "nsfw" (lowercase). Do not output other English tags besides "nsfw" when the prompt language is not English.
 - You MUST output image_descriptions[] covering ALL images. Each item: {from_file:"image index string", to_file:"image index string", description:"at least 6 natural language sentences (aim for 8-12 if reasonable)"}. You may merge highly similar consecutive images (e.g., continuous chat screenshots) into one description group and use from_file/to_file to denote the range. Ensure every image index is covered exactly once (no missing, no duplicates).
 - For retrieval/semantic search, each description must be detailed and multi-angle (scene/layout/key elements/likely action & intent/state changes) and include as many concrete searchable keywords/entities as possible (app/page/feature/people/places/product/workflow, etc.). Do NOT transcribe long on-screen text and do NOT output a separate "Visible text" field/section. Append exactly ONE final line to each description: `Keywords: ...` (many items; include synonyms/split-words/abbreviations when helpful; aim for 20+ keywords).
 - key_actions[].ref_image MUST reference one of the input image indexes (string).
 """.trim()
            }

            // 结构化呈现规则：开头一段纯文本总结，随后 Markdown 小节
            val dynamicStructureRule = if (isZhForRule) {
                "- 开头先输出一段对本时间段的简短总结（纯文本，不使用任何标题；不要出现\\\"## 概览\\\"或\\\"## 总结\\\"等）；随后再使用 Markdown 小节呈现后续内容。"
            } else {
                "- Start with one plain paragraph (no heading) summarizing the time window; then present details using Markdown subsections."
            }
            // 常规总结仍在开头和结尾重复规则；OpenAI 兼容的合并总结则只保留一份，
            // 以降低提示词长度并避免要求重复生成已可从原事件继承的图片元数据。
            val headRules = listOf(dynamicCapRule, dynamicImageRule, dynamicStructureRule)
                .filter { it.isNotEmpty() }
                .joinToString("\n")
            if (headRules.isNotEmpty()) {
                if (slimOpenAiMergePrompt) {
                    "$headRules\n\n$prompt"
                } else {
                    "$headRules\n\n$prompt\n$headRules"
                }
            } else {
                prompt
            }
        }
        if (diagEnabled) {
            logBackfillDiag(
                ctx,
                "aiCall promptReady seg=${seg.id} promptLen=${prompt.length} promptWithRuleLen=${promptWithRule.length} " +
                    "injectDynamicRules=$injectDynamicRules isGoogle=$isGoogle isMerge=$isMerge " +
                    "promptPrefix1024=${promptPrefixHash(prompt, 1024)} promptWithRulePrefix1024=${promptPrefixHash(promptWithRule, 1024)}",
            )
        }

        // 速率限制：必要时等待
        if (diagEnabled) {
            logBackfillDiag(ctx, "aiCall rateLimitBefore seg=${seg.id}")
        }
        val waited = acquireAiRateSlot(ctx)
        if (diagEnabled) {
            logBackfillDiag(ctx, "aiCall rateLimitAfter seg=${seg.id} waitedMs=$waited")
        }

        // 配置校验与请求前日志
        try {
            if (apiKey.isNullOrBlank()) {
                FileLogger.e(TAG, "AI 配置错误：缺少 apiKey")
            }
            if (base.isBlank()) {
                FileLogger.e(TAG, "AI 配置错误：缺少 baseUrl")
            }
            if (model.isBlank()) {
                FileLogger.e(TAG, "AI 配置提示：model 为空，如服务端支持将使用默认模型")
            }
            if (waited > 0L) {
                FileLogger.i(TAG, "AI 因速率限制等待了 ${waited}毫秒")
            }
        } catch (_: Exception) {}

        // 统计图片字节与预览
        var totalImageBytes = 0L
        var missingImages = 0
        val firstNames = ArrayList<String>()
        for (s in effSamples) {
            try {
                val f = File(s.filePath)
                val size = if (f.exists()) f.length() else 0L
                if (size <= 0L) missingImages++ else totalImageBytes += size
                if (firstNames.size < 6) firstNames.add(f.name)
            } catch (_: Exception) { missingImages++ }
        }
        val textLen = prompt.length
        val textLenWithRule = promptWithRule.length
        try {
            FileLogger.i(
                TAG,
                "AI 准备：提供方=${if (isGoogle) "google" else "openai-compat"}, 模型=${model}, baseUrl=${base}, 段ID=${seg.id}, 合并=${isMerge}, 文本长度=${textLen}, 文本长度(含规则)=${textLenWithRule}, 图片数=${samples.size}, 实际发送=${effSamples.size}, 字节数=${totalImageBytes}, 缺失图片=${missingImages}, 疑似损坏图片=${damagedImages}, 前几个文件=${firstNames.joinToString("|")}"
            )
        } catch (_: Exception) {}
        try {
            val promptPreview = truncateForLog(promptWithRule, 800)
            FileLogger.i(TAG, "AI 提示词预览：${promptPreview}")
        } catch (_: Exception) {}
        try {
            OutputFileLogger.info(ctx, TAG, "AI 准备：提供方=${if (isGoogle) "google" else "openai-compat"}, 模型=${model}, baseUrl=${base}, 段ID=${seg.id}, 合并=${isMerge}, 文本长度=${textLen}, 文本长度(含规则)=${textLenWithRule}, 图片数=${samples.size}, 实际发送=${effSamples.size}, 字节数=${totalImageBytes}, 缺失图片=${missingImages}, 疑似损坏图片=${damagedImages}, 前几个文件=${firstNames.joinToString("|")}")
        } catch (_: Exception) {}
        if (diagEnabled) {
            logBackfillDiag(
                ctx,
                "aiCall imageStatsDone seg=${seg.id} totalImageBytes=$totalImageBytes missingImages=$missingImages " +
                    "damagedImages=$damagedImages firstFiles=${firstNames.joinToString("|")}",
            )
        }

        // 额外打印提示词预览（不含图片/密钥）：Logcat 截断 + 文件完整
        try {
            val promptPreview = truncateForLog(promptWithRule, 800)
            FileLogger.i(TAG, "AI 提示词预览：${promptPreview}")
        } catch (_: Exception) {}
        val url = if (isGoogle) {
            buildGeminiUrl(base, model, geminiUseStreaming)
        } else {
            // OpenAI 兼容 REST: POST {base}{chatPath}；必要时可切到 /v1/responses
            primaryOpenAiUrl
        }
        val t0 = System.currentTimeMillis()
        val requestId = "seg${seg.id}_${System.nanoTime()}"
        val providerLabel = if (isGoogle) "google" else "openai-compat"
        if (diagEnabled) {
            logBackfillDiag(
                ctx,
                "aiCall requestContextReady seg=${seg.id} requestId=$requestId provider=$providerLabel " +
                    "url=$url model=$model images=${effSamples.size}/${samples.size} promptLen=$textLenWithRule " +
                    "promptPrefix2048=${promptPrefixHash(prompt, 2048)} promptWithRulePrefix2048=${promptPrefixHash(promptWithRule, 2048)}",
            )
        }
        val stageSpec = resolveDynamicAiStageSpec(stageScope)
        val heartbeatStop = AtomicBoolean(false)
        val heartbeatAttempt = AtomicInteger(1)
        val heartbeatResponseCode = AtomicInteger(-1)
        val heartbeatResponseHeadersAtMs = AtomicLong(0L)
        val heartbeatLastEventAtMs = AtomicLong(0L)
        val heartbeatEventCount = AtomicInteger(0)
        val heartbeatPhase = AtomicReference("流式请求")
        val heartbeatTimer = if (stageReporter != null && stageSpec != null) {
            val heartbeatReporter = stageReporter
            val heartbeatSpec = stageSpec
            Timer("dynamic-ai-heartbeat-$requestId", true).apply {
                scheduleAtFixedRate(object : TimerTask() {
                    override fun run() {
                        if (heartbeatStop.get()) return
                        try {
                            val now = System.currentTimeMillis()
                            val elapsedSec = ((now - t0).coerceAtLeast(0L)) / 1000L
                            val responseCode = heartbeatResponseCode.get()
                            val eventCount = heartbeatEventCount.get()
                            val responseHeadersAt = heartbeatResponseHeadersAtMs.get()
                            val lastEventAt = heartbeatLastEventAtMs.get()
                            val detailParts = ArrayList<String>(8)
                            detailParts.add("requestId=$requestId")
                            detailParts.add("已等待 ${elapsedSec} 秒")
                            detailParts.add("尝试 ${heartbeatAttempt.get()}/3")
                            detailParts.add("阶段=${heartbeatPhase.get()}")
                            detailParts.add("provider=$providerLabel")
                            if (model.isNotBlank()) detailParts.add("model=$model")
                            if (responseCode >= 0) detailParts.add("HTTP=$responseCode")
                            when {
                                eventCount > 0 && lastEventAt > 0L -> {
                                    val idleSec =
                                        ((now - lastEventAt).coerceAtLeast(0L)) / 1000L
                                    detailParts.add("已收 ${eventCount} 条数据事件")
                                    detailParts.add("最近事件 ${idleSec} 秒前")
                                }
                                responseHeadersAt > 0L -> {
                                    val idleSec =
                                        ((now - responseHeadersAt).coerceAtLeast(0L)) / 1000L
                                    detailParts.add("已收到响应头，尚未收到数据事件")
                                    detailParts.add("距响应头 ${idleSec} 秒")
                                }
                                else -> detailParts.add("尚未收到响应头")
                            }
                            heartbeatReporter.invoke(
                                heartbeatSpec.heartbeatStage,
                                heartbeatSpec.heartbeatLabel,
                                detailParts.joinToString("，"),
                                seg.id,
                            )
                        } catch (_: Exception) {
                        }
                    }
                }, DYNAMIC_AI_HEARTBEAT_INTERVAL_MS, DYNAMIC_AI_HEARTBEAT_INTERVAL_MS)
            }
        } else {
            null
        }
        fun logStructuredRequest(message: String) {
            try { OutputFileLogger.info(ctx, TAG, message) } catch (_: Exception) {}
        }
        try {
            logStructuredRequest("AIREQ PROMPT_BEGIN id=$requestId")
            OutputFileLogger.info(ctx, TAG, "AI 提示词完整内容开始 >>>")
            OutputFileLogger.info(ctx, TAG, promptWithRule)
            OutputFileLogger.info(ctx, TAG, "AI 提示词完整内容结束 <<<")
            logStructuredRequest("AIREQ PROMPT_END id=$requestId")
        } catch (_: Exception) {}
        fun buildRequestTrace(): String {
            val sb = StringBuilder()
            sb.append("=== AI Request ===").append('\n')
            sb.append("provider=").append(if (isGoogle) "google" else "openai-compat").append('\n')
            sb.append("url=").append(url).append('\n')
            sb.append("model=").append(model).append('\n')
            sb.append("segment_id=").append(seg.id).append('\n')
            sb.append("is_merge=").append(isMerge).append('\n')
            sb.append("prompt_len=").append(textLenWithRule).append('\n')
            sb.append("images_attached=").append(effSamples.size).append('\n')
            sb.append("images_total=").append(samples.size).append('\n')
            sb.append("images_bytes_total=").append(totalImageBytes).append('\n')
            sb.append("missing_images=").append(missingImages).append('\n')
            sb.append('\n')
            sb.append("prompt:").append('\n')
            sb.append(promptWithRule).append('\n')
            sb.append('\n')
            sb.append("images:").append('\n')
            for ((idx, s) in effSamples.withIndex()) {
                val appDisplay = s.appName.trim().ifEmpty { s.appPackageName.trim() }
                val fileName = try { File(s.filePath).name } catch (_: Exception) { "" }
                val size = try {
                    val f = File(s.filePath)
                    if (f.exists()) f.length() else 0L
                } catch (_: Exception) { 0L }
                sb.append("#").append(idx + 1)
                    .append(" time=").append(fmt(s.captureTime))
                    .append(" app=").append(appDisplay)
                    .append(" file=").append(fileName)
                    .append(" path=").append(s.filePath)
                    .append(" mime=").append(guessMime(s.filePath))
                    .append(" bytes=").append(size)
                    .append('\n')
            }
            return sb.toString().trimEnd()
        }
        val rawRequestTrace: String? = try { buildRequestTrace() } catch (_: Exception) { null }
        if (diagEnabled) {
            logBackfillDiag(
                ctx,
                "aiCall rawRequestTraceReady seg=${seg.id} requestId=$requestId rawRequestLen=${rawRequestTrace?.length ?: 0}",
            )
        }
        logStructuredRequest(
            "AIREQ START id=$requestId provider=$providerLabel segment_id=${seg.id} is_merge=$isMerge url=$url model=$model images_attached=${effSamples.size} images_total=${samples.size} prompt_len=$textLenWithRule " +
                "prompt_prefix_1024=${promptPrefixHash(promptWithRule, 1024)} prompt_prefix_2048=${promptPrefixHash(promptWithRule, 2048)} timeout_ms=${requestTimeoutMs ?: 0L}"
        )
        if (diagEnabled) {
            logBackfillDiag(ctx, "aiCall aireqStartLogged seg=${seg.id} requestId=$requestId")
        }

        try {
            if (isGoogle) {
            try { FileLogger.i(TAG, "AI 请求：地址=$url 模型=$model 图片数=${effSamples.size}") } catch (_: Exception) {}
            try { FileLogger.i(TAG, "AI 请求：地址=$url 模型=$model 图片数=${effSamples.size}") } catch (_: Exception) {}
            try { OutputFileLogger.info(ctx, TAG, "AI 请求：地址=$url 模型=$model 图片数=${effSamples.size}") } catch (_: Exception) {}

            val parts = JSONArray()
            parts.put(JSONObject().put("text", promptWithRule))
            var encodedImages = 0
            var skippedPayloadImages = 0
            for (s in effSamples) {
                val payload = prepareImagePayloadForAi(ctx, s.filePath)
                if (payload == null || payload.bytes.isEmpty()) {
                    skippedPayloadImages += 1
                    continue
                }
                val b64 = Base64.encodeToString(payload.bytes, Base64.NO_WRAP)
                val inline = JSONObject()
                    .put("mimeType", payload.mime)
                    .put("data", b64)
                parts.put(JSONObject().put("inlineData", inline))
                encodedImages += 1
            }
            val contents = JSONArray().put(JSONObject().put("parts", parts))
            val body = JSONObject().put("contents", contents).toString()
            if (diagEnabled) {
                logBackfillDiag(
                    ctx,
                    "aiCall requestBodyReady seg=${seg.id} requestId=$requestId provider=google " +
                        "encodedImages=$encodedImages skippedPayloadImages=$skippedPayloadImages bodyLen=${body.length} " +
                        "bodyPrefix1024=${promptPrefixHash(body, 1024)}",
                )
            }
            val reqBody: RequestBody = body.toRequestBody("application/json; charset=utf-8".toMediaType())
            val req = Request.Builder()
                .url(url)
                .addHeader("x-goog-api-key", apiKey ?: "")
                .addHeader("Accept", if (geminiUseStreaming) "text/event-stream" else "application/json")
                .post(reqBody)
                .build()
            var respText = ""
            var outputText = ""
            run {
                var attempt = 0
                val maxAttempts = 3
                var lastCode = -1
                var lastBody: String? = null
                var lastFailure: Throwable? = null
                var lastFailureKind: String? = null
                while (attempt < maxAttempts) {
                    maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                    if (diagEnabled) {
                        logBackfillDiag(
                            ctx,
                            "aiCall attemptStart seg=${seg.id} requestId=$requestId provider=google " +
                                "attempt=${attempt + 1}/$maxAttempts url=$url",
                        )
                    }
                    heartbeatAttempt.set(attempt + 1)
                    heartbeatPhase.set("流式请求")
                    heartbeatResponseCode.set(-1)
                    heartbeatResponseHeadersAtMs.set(0L)
                    heartbeatLastEventAtMs.set(0L)
                    heartbeatEventCount.set(0)
                    val start = System.currentTimeMillis()
                    try {
                        var finished = false
                        executeTrackedCall(
                            ctx = ctx,
                            stageScope = stageScope,
                            segmentId = seg.id,
                            call = client.newCall(req),
                        ) { resp ->
                            val end = System.currentTimeMillis()
                            lastCode = resp.code
                            heartbeatResponseCode.set(resp.code)
                            heartbeatResponseHeadersAtMs.set(end)
                            try { FileLogger.i(TAG, "AI 响应元信息：code=${resp.code} 耗时毫秒=${end - start} 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                            try { FileLogger.i(TAG, "AI 响应元信息：code=${resp.code} 耗时毫秒=${end - start} 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                            try { OutputFileLogger.info(ctx, TAG, "AI 响应元信息：code=${resp.code} 耗时毫秒=${end - start} 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                            logStructuredRequest("AIREQ RESP id=$requestId code=${resp.code} took_ms=${end - start} attempt=${attempt + 1}/${maxAttempts}")
                            if (resp.isSuccessful) {
                                val responseBody = resp.body ?: throw IllegalStateException("Empty response body")
                                if (geminiUseStreaming) {
                                    val reader = responseBody.charStream().buffered()
                                    val aggregated = StringBuilder()
                                    val rawEvents = StringBuilder()
                                    val previewBuffer = StringBuilder()
                                    var sawData = false
                                    var lastCumulative = ""
                                    var payloadError: String? = null
                                    reader.use { buffered ->
                                        while (true) {
                                            val line = buffered.readLine() ?: break
                                            if (line.isEmpty()) continue
                                            if (!line.startsWith("data:")) continue
                                            val data = line.substring(5).trim()
                                            if (data.isEmpty()) continue
                                            if (data == "[DONE]") break
                                            sawData = true
                                            heartbeatEventCount.incrementAndGet()
                                            heartbeatLastEventAtMs.set(System.currentTimeMillis())
                                            rawEvents.append(data).append('\n')
                                            try {
                                                val obj = JSONObject(data)
                                                if (obj.has("error")) {
                                                    payloadError = obj.optJSONObject("error")?.toString()
                                                        ?: obj.optString("error")
                                                    break
                                                }
                                                var chunkText = ""
                                                val candidates = obj.optJSONArray("candidates")
                                                if (candidates != null && candidates.length() > 0) {
                                                    val c0 = candidates.optJSONObject(0)
                                                    val content = c0?.optJSONObject("content")
                                                    val partsOut = content?.optJSONArray("parts")
                                                    if (partsOut != null && partsOut.length() > 0) {
                                                        val sb = StringBuilder()
                                                        for (i in 0 until partsOut.length()) {
                                                            val p = partsOut.optJSONObject(i) ?: continue
                                                            // Gemini "thinking" mode may emit reasoning as parts with `thought=true`.
                                                            // Those are not user-facing content; skip them to avoid polluting outputText.
                                                            if (p.optBoolean("thought", false)) continue
                                                            val t = p.optString("text")
                                                            if (t.isNotBlank()) sb.append(t)
                                                        }
                                                        chunkText = sb.toString()
                                                    }
                                                }
                                                if (chunkText.isBlank()) continue
                                                val delta = if (chunkText.startsWith(lastCumulative)) {
                                                    chunkText.substring(lastCumulative.length)
                                                } else {
                                                    chunkText
                                                }
                                                if (delta.isNotBlank()) {
                                                    aggregated.append(delta)
                                                    appendDynamicAiStreamPreviewChunk(
                                                        buffer = previewBuffer,
                                                        rawChunk = delta,
                                                        emit = { preview ->
                                                            reportDynamicAiStreamChunk(
                                                                stageReporter = stageReporter,
                                                                stageScope = stageScope,
                                                                segmentId = seg.id,
                                                                chunkPreview = preview,
                                                            )
                                                        },
                                                    )
                                                }
                                                lastCumulative = if (chunkText.startsWith(lastCumulative)) {
                                                    chunkText
                                                } else {
                                                    lastCumulative + chunkText
                                                }
                                            } catch (_: Exception) {
                                                // ignore malformed event chunk
                                            }
                                        }
                                    }
                                    flushDynamicAiStreamPreviewBuffer(previewBuffer) { preview ->
                                        reportDynamicAiStreamChunk(
                                            stageReporter = stageReporter,
                                            stageScope = stageScope,
                                            segmentId = seg.id,
                                            chunkPreview = preview,
                                        )
                                    }
                                    respText = rawEvents.toString()
                                    if (!sawData) {
                                        throw IllegalStateException("No SSE data received: ${respText.take(800)}")
                                    }
                                    if (payloadError != null) {
                                        // 保留 rawEvents 供前端展示错误预览
                                        finished = true
                                    } else {
                                        outputText = aggregated.toString()
                                        if (outputText.isBlank() && respText.isNotBlank()) {
                                            try {
                                                val repaired = extractTextFromGeminiBody(respText)
                                                if (repaired.isNotBlank()) {
                                                    outputText = repaired
                                                }
                                            } catch (_: Exception) {}
                                        }
                                        finished = true
                                    }
                                } else {
                                    val bodyText = responseBody.string()
                                    respText = bodyText
                                    outputText = extractTextFromGeminiBody(bodyText)
                                    finished = true
                                }
                            } else {
                                lastBody = resp.body?.string()
                                val failureBody = lastBody
                                if (!failureBody.isNullOrEmpty()) {
                                    val lower = failureBody.lowercase()
                                    if (lower.contains("user location is not supported")) {
                                        try { FileLogger.e(TAG, "Gemini 请求因地区策略被阻止：${truncateForLog(failureBody, 800)}") } catch (_: Exception) {}
                                        logStructuredRequest("AIREQ ERR id=$requestId kind=region_block code=${resp.code} attempt=${attempt + 1}/${maxAttempts}")
                                    }
                                }
                                val shouldRetry = resp.code >= 500
                                try { FileLogger.w(TAG, "AI 请求失败(code=${resp.code}) 尝试=${attempt + 1}/${maxAttempts} 响应体=${truncateForLog(lastBody ?: "", 800)}") } catch (_: Exception) {}
                                try { FileLogger.w(TAG, "AI 请求失败(code=${resp.code}) 尝试=${attempt + 1}/${maxAttempts} 响应体=${truncateForLog(lastBody ?: "", 800)}") } catch (_: Exception) {}
                                try { OutputFileLogger.error(ctx, TAG, "AI 请求失败(code=${resp.code}) 尝试=${attempt + 1}/${maxAttempts} 响应体=${truncateForLog(lastBody ?: "", 800)}") } catch (_: Exception) {}
                                logStructuredRequest("AIREQ ERR id=$requestId kind=http code=${resp.code} attempt=${attempt + 1}/${maxAttempts}")
                                if (!shouldRetry) throw IllegalStateException("Request failed: ${resp.code} ${lastBody}")
                            }
                        }
                        if (finished) break
                    } catch (e: java.net.SocketTimeoutException) {
                        maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                        lastFailure = e
                        lastFailureKind = "timeout"
                        try { FileLogger.w(TAG, "AI 请求超时 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                        try { FileLogger.w(TAG, "AI 请求超时 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                        try { OutputFileLogger.error(ctx, TAG, "AI 请求超时 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                        logStructuredRequest("AIREQ ERR id=$requestId kind=timeout attempt=${attempt + 1}/${maxAttempts}")
                        // 继续重试
                    } catch (e: java.io.InterruptedIOException) {
                        maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                        lastFailure = e
                        lastFailureKind =
                            if ((e.message ?: "").contains("timeout", ignoreCase = true)) {
                                "timeout"
                            } else {
                                "interrupted"
                            }
                        try { FileLogger.w(TAG, "AI 请求中断 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        try { OutputFileLogger.error(ctx, TAG, "AI 请求中断 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        logStructuredRequest("AIREQ ERR id=$requestId kind=interrupted attempt=${attempt + 1}/${maxAttempts}")
                    } catch (e: Exception) {
                        maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                        lastFailure = e
                        lastFailureKind = "exception"
                        // 其他IO异常：仅第一次尝试记录，仍然重试
                        try { FileLogger.w(TAG, "AI 请求异常 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        try { FileLogger.w(TAG, "AI 请求异常 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        try { OutputFileLogger.error(ctx, TAG, "AI 请求异常 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        logStructuredRequest("AIREQ ERR id=$requestId kind=exception attempt=${attempt + 1}/${maxAttempts}")
                    }
                    attempt++
                    if (attempt < maxAttempts) {
                        val backoff = (1000L * (1 shl (attempt - 1))).coerceAtMost(5000L)
                        sleepWithDynamicCancelAwareness(ctx, stageScope, seg.id, backoff)
                    } else if (lastCode >= 0) {
                        throw IllegalStateException("Request failed: ${lastCode} ${lastBody}")
                    } else if (lastFailure != null) {
                        throw IllegalStateException(
                            buildAiTerminalFailureMessage(
                                lastFailureKind = lastFailureKind,
                                lastFailure = lastFailure,
                                maxAttempts = maxAttempts,
                                requestTimeoutMs = requestTimeoutMs,
                            ),
                        )
                    } else {
                        throw IllegalStateException("Request failed: unknown error")
                    }
                }
            }
            try {
                FileLogger.d(TAG, "AI 响应长度=${respText.length}")
                val preview = truncateForLog(respText, 2000)
                FileLogger.i(TAG, "AI 响应预览：${preview}")
            } catch (_: Exception) {}
            try {
                val preview = truncateForLog(respText, 2000)
                FileLogger.i(TAG, "AI 响应预览：${preview}")
            } catch (_: Exception) {}
            // 完整响应落盘（分块写入）
            try {
                logStructuredRequest("AIREQ RESP_BODY_BEGIN id=$requestId")
                OutputFileLogger.info(ctx, TAG, "AI 响应完整内容开始 >>>")
                val text = respText
                val chunk = 1800
                var i = 0
                while (i < text.length) {
                    val end = kotlin.math.min(i + chunk, text.length)
                    OutputFileLogger.info(ctx, TAG, text.substring(i, end))
                    i = end
                }
                OutputFileLogger.info(ctx, TAG, "AI 响应完整内容结束 <<<")
                logStructuredRequest("AIREQ RESP_BODY_END id=$requestId")
            } catch (_: Exception) {}
            try {
                val preview = truncateForLog(respText, 2000)
                OutputFileLogger.info(ctx, TAG, "AI 响应预览：${preview}")
            } catch (_: Exception) {}
            // 若无正常内容且响应体包含 error，则回落为直接保存错误预览，供前端显示
            if (outputText.isBlank()) {
                if (strictFailure) {
                    throw IllegalStateException(
                        buildAiPayloadFailureMessage("Google", respText),
                    )
                }
                try {
                    val low = respText.lowercase()
                    outputText = when {
                        low.contains("\"error\"") || low.contains("no candidates returned") -> {
                            "AI response preview(Google): " + respText
                        }
                        respText.isNotBlank() -> {
                            "AI empty content(Google), raw response: " + truncateForLog(respText, 2000)
                        }
                        else -> "AI empty response(Google)"
                    }
                } catch (_: Exception) {}
            }
            val (structured, cats) = extractJsonBlocks(outputText)
            // 结构化 JSON 完整输出（Pretty JSON + 分块）
            try {
                if (structured != null && structured.trim().isNotEmpty()) {
                    var pretty = structured
                    try {
                        val jo = JSONObject(structured)
                        pretty = jo.toString(2)
                    } catch (_: Exception) {
                        try {
                            val ja = JSONArray(structured)
                            pretty = ja.toString(2)
                        } catch (_: Exception) {}
                    }
                    OutputFileLogger.info(ctx, TAG, "AI structured_json 开始 >>>")
                    val textSJ = pretty
                    val chunkSJ = 1800
                    var p = 0
                    while (p < textSJ.length) {
                        val end = kotlin.math.min(p + chunkSJ, textSJ.length)
                        OutputFileLogger.info(ctx, TAG, textSJ.substring(p, end))
                        p = end
                    }
                    OutputFileLogger.info(ctx, TAG, "AI structured_json 结束 <<<")
                } else {
                    OutputFileLogger.info(ctx, TAG, "AI structured_json 为空")
                }
                if (cats != null && cats.trim().isNotEmpty()) {
                    OutputFileLogger.info(ctx, TAG, "AI 分类：${cats}")
                }
            } catch (_: Exception) {}
            logStructuredRequest("AIREQ DONE id=$requestId content_len=${outputText.length} response_len=${respText.length}")
            return finalizeAiResultJson(
                ctx = ctx,
                seg = seg,
                samples = effSamples,
                prompt = prompt,
                isMerge = isMerge,
                injectDynamicRules = injectDynamicRules,
                maxImagesOverride = maxImagesOverride,
                allowJsonAutoRetry = allowJsonAutoRetry,
                jsonRetryCount = jsonRetryCount,
                aiConfigOverride = aiConfigOverride,
                strictFailure = strictFailure,
                model = model,
                outputText = outputText,
                structured = structured,
                categories = cats,
                rawRequest = rawRequestTrace,
                rawResponse = respText,
                stageReporter = stageReporter,
                stageScope = stageScope,
            )
        } else {
            try { FileLogger.i(TAG, "AI 请求(OpenAI兼容)：地址=$url 模型=$model 图片数=${effSamples.size}") } catch (_: Exception) {}
            try { FileLogger.i(TAG, "AI 请求(OpenAI兼容)：地址=$url 模型=$model 图片数=${effSamples.size}") } catch (_: Exception) {}
            try { OutputFileLogger.info(ctx, TAG, "AI 请求(OpenAI兼容)：地址=$url 模型=$model 图片数=${effSamples.size}") } catch (_: Exception) {}

            val contentArr = JSONArray()
            contentArr.put(JSONObject().put("type", "text").put("text", promptWithRule))
            var encodedImages = 0
            var skippedPayloadImages = 0
            for (s in effSamples) {
                val payload = prepareImagePayloadForAi(ctx, s.filePath)
                if (payload == null || payload.bytes.isEmpty()) {
                    skippedPayloadImages += 1
                    continue
                }
                val b64 = Base64.encodeToString(payload.bytes, Base64.NO_WRAP)
                val dataUrl = "data:" + payload.mime + ";base64," + b64
                val imageUrl = JSONObject().put("url", dataUrl)
                contentArr.put(JSONObject().put("type", "image_url").put("image_url", imageUrl))
                encodedImages += 1
            }
            val messages = JSONArray().put(JSONObject()
                .put("role", "user")
                .put("content", contentArr)
            )
            fun buildChatBody(stream: Boolean): String {
                return JSONObject()
                    .put("model", model)
                    .put("messages", messages)
                    .put("stream", stream)
                    .toString()
            }

            fun buildResponsesBody(stream: Boolean): String {
                val parts = JSONArray()
                for (i in 0 until contentArr.length()) {
                    val item = contentArr.optJSONObject(i) ?: continue
                    when (item.optString("type")) {
                        "text" -> {
                            val t = item.optString("text")
                            if (t.isNotBlank()) {
                                parts.put(
                                    JSONObject()
                                        .put("type", "input_text")
                                        .put("text", t),
                                )
                            }
                        }

                        "image_url" -> {
                            val img = item.optJSONObject("image_url")
                            val u = img?.optString("url") ?: ""
                            if (u.isNotBlank()) {
                                parts.put(
                                    JSONObject()
                                        .put("type", "input_image")
                                        .put("image_url", u),
                                )
                            }
                        }
                    }
                }
                val input = JSONArray().put(
                    JSONObject()
                        .put("role", "user")
                        .put("content", parts),
                )
                return JSONObject()
                    .put("model", model)
                    .put("input", input)
                    .put("stream", stream)
                    .toString()
            }

            val bodyStream =
                if (preferResponsesApi) buildResponsesBody(true) else buildChatBody(true)
            val bodyNonStream =
                if (preferResponsesApi) buildResponsesBody(false) else buildChatBody(false)
            if (diagEnabled) {
                logBackfillDiag(
                    ctx,
                    "aiCall requestBodyReady seg=${seg.id} requestId=$requestId provider=openai-compat " +
                        "encodedImages=$encodedImages skippedPayloadImages=$skippedPayloadImages " +
                        "bodyStreamLen=${bodyStream.length} bodyNonStreamLen=${bodyNonStream.length} " +
                        "preferResponsesApi=$preferResponsesApi allowResponsesFallback=$allowResponsesFallback " +
                        "bodyStreamPrefix1024=${promptPrefixHash(bodyStream, 1024)} bodyNonStreamPrefix1024=${promptPrefixHash(bodyNonStream, 1024)}",
                )
            }

            fun buildReq(targetUrl: String, body: String, accept: String): Request {
                val reqBody: RequestBody =
                    body.toRequestBody("application/json; charset=utf-8".toMediaType())
                return Request.Builder()
                    .url(targetUrl)
                    .post(reqBody)
                    .addHeader("Authorization", "Bearer $apiKey")
                    .addHeader("Content-Type", "application/json")
                    .addHeader("Accept", accept)
                    .build()
            }
            val reqStream = buildReq(url, bodyStream, "text/event-stream")
            val reqNonStream = buildReq(url, bodyNonStream, "application/json")
            var respText = ""
            var outputText = ""
            run {
                var attempt = 0
                val maxAttempts = 3
                var lastCode = -1
                var lastBody: String? = null
                var lastFailure: Throwable? = null
                var lastFailureKind: String? = null
                while (attempt < maxAttempts) {
                    maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                    if (diagEnabled) {
                        logBackfillDiag(
                            ctx,
                            "aiCall attemptStart seg=${seg.id} requestId=$requestId provider=openai-compat " +
                                "attempt=${attempt + 1}/$maxAttempts url=$url",
                        )
                    }
                    heartbeatAttempt.set(attempt + 1)
                    heartbeatPhase.set("流式请求")
                    heartbeatResponseCode.set(-1)
                    heartbeatResponseHeadersAtMs.set(0L)
                    heartbeatLastEventAtMs.set(0L)
                    heartbeatEventCount.set(0)
                    val start = System.currentTimeMillis()
                    try {
                        var finished = false
                        executeTrackedCall(
                            ctx = ctx,
                            stageScope = stageScope,
                            segmentId = seg.id,
                            call = client.newCall(reqStream),
                        ) { resp ->
                            val end = System.currentTimeMillis()
                            lastCode = resp.code
                            heartbeatResponseCode.set(resp.code)
                            heartbeatResponseHeadersAtMs.set(end)
                            try { FileLogger.i(TAG, "AI 响应元信息(OpenAI兼容)：code=${resp.code} 耗时毫秒=${end - start} 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                            try { FileLogger.i(TAG, "AI 响应元信息(OpenAI兼容)：code=${resp.code} 耗时毫秒=${end - start} 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                            try { OutputFileLogger.info(ctx, TAG, "AI 响应元信息(OpenAI兼容)：code=${resp.code} 耗时毫秒=${end - start} 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                            logStructuredRequest("AIREQ RESP id=$requestId code=${resp.code} took_ms=${end - start} attempt=${attempt + 1}/${maxAttempts}")
                            if (resp.isSuccessful) {
                                val responseBody = resp.body ?: throw IllegalStateException("Empty response body")
                                val streamRead =
                                    readOpenAiCompatibleStreamBody(
                                        ctx = ctx,
                                        stageScope = stageScope,
                                        segmentId = seg.id,
                                        responseBody = responseBody,
                                        requestTimeoutMs = requestTimeoutMs,
                                        onDataEvent = { eventAtMs ->
                                            heartbeatLastEventAtMs.set(eventAtMs)
                                            heartbeatEventCount.incrementAndGet()
                                        },
                                        onPreviewChunk = { preview ->
                                            reportDynamicAiStreamChunk(
                                                stageReporter = stageReporter,
                                                stageScope = stageScope,
                                                segmentId = seg.id,
                                                chunkPreview = preview,
                                            )
                                        },
                                    )
                                val respBodyText = streamRead.body
                                respText = respBodyText
                                val parsedStream =
                                    parseOpenAiCompatibleIncrementalBody(respBodyText)
                                val sawData = parsedStream.sawData || streamRead.sawData
                                val payloadError = parsedStream.payloadError
                                if (streamRead.firstEventTimedOut) {
                                    try {
                                        FileLogger.w(
                                            TAG,
                                            "OpenAI 流式已收到响应头，但在 ${DYNAMIC_AI_STREAM_FIRST_EVENT_TIMEOUT_MS}ms 内未等到首个数据事件；准备回退非流式",
                                        )
                                    } catch (_: Exception) {}
                                    logStructuredRequest(
                                        "AIREQ STREAM_WAIT_TIMEOUT id=$requestId first_event_timeout_ms=$DYNAMIC_AI_STREAM_FIRST_EVENT_TIMEOUT_MS partial_len=${respText.length}",
                                    )
                                }
                                try {
                                    logStructuredRequest(
                                        "AIREQ STREAM_PARSE id=$requestId sawData=$sawData decodedEvents=${parsedStream.decodedEvents} content_len=${parsedStream.content.length} reasoning_len=${parsedStream.reasoning.length} payload_error=${truncateForLog(payloadError ?: "", 200)} preview=${truncateForLog(respText, 400)}",
                                    )
                                } catch (_: Exception) {}
                                if (parsedStream.decodedEvents > 0) {
                                    if (parsedStream.decodedEvents > heartbeatEventCount.get()) {
                                        heartbeatEventCount.set(parsedStream.decodedEvents)
                                    }
                                    heartbeatLastEventAtMs.set(System.currentTimeMillis())
                                }
                                if (payloadError != null) {
                                    // 保留 rawEvents 供前端展示错误预览
                                    try { FileLogger.w(TAG, "AI 成功(200)但响应体为错误(OpenAI)：body=${truncateForLog(respText, 800)}") } catch (_: Exception) {}
                                    try { OutputFileLogger.error(ctx, TAG, "AI 成功(200)但响应体为错误(OpenAI)：body=${truncateForLog(respText, 800)}") } catch (_: Exception) {}
                                    finished = true
                                } else {
                                    outputText = parsedStream.content
                                    if (outputText.isBlank() && respText.isNotBlank()) {
                                        try {
                                            val repaired = extractTextFromOpenAiCompatibleBody(respText)
                                            if (repaired.isNotBlank()) {
                                                outputText = repaired
                                            }
                                        } catch (_: Exception) {}
                                    }
                                    val gotReasoningOnly =
                                        outputText.isBlank() &&
                                            parsedStream.reasoning.isNotBlank()
                                    if (gotReasoningOnly) {
                                        // Some gateways stream thinking but fail to stream/return the final answer.
                                        // We do NOT downgrade reasoning to user-facing content; instead, try a non-stream fallback.
                                        try {
                                            FileLogger.w(
                                                TAG,
                                                "OpenAI 流式仅收到 reasoning，正文为空；尝试用非流式回退获取正文",
                                            )
                                        } catch (_: Exception) {}
                                    }

                                    if (outputText.isBlank()) {
                                        heartbeatPhase.set("非流式回退")
                                        heartbeatResponseCode.set(-1)
                                        heartbeatResponseHeadersAtMs.set(0L)
                                        heartbeatLastEventAtMs.set(0L)
                                        heartbeatEventCount.set(0)
                                        reportDynamicAiFallback(
                                            stageReporter = stageReporter,
                                            stageScope = stageScope,
                                            segmentId = seg.id,
                                            detail =
                                                when {
                                                    gotReasoningOnly -> {
                                                        "流式只返回 reasoning，正文为空，开始回退到非流式 ${primaryOpenAiLabel}；requestId=$requestId"
                                                    }
                                                    streamRead.firstEventTimedOut -> {
                                                        "流式已收到响应头，但等待首个数据事件超时，开始回退到非流式 ${primaryOpenAiLabel}；requestId=$requestId"
                                                    }
                                                    !sawData -> {
                                                        "流式未收到可解析的数据事件，开始回退到非流式 ${primaryOpenAiLabel}；requestId=$requestId"
                                                    }
                                                    else -> {
                                                        "流式正文为空，开始回退到非流式 ${primaryOpenAiLabel}；requestId=$requestId"
                                                    }
                                                },
                                        )
                                        // Fallback to the non-streaming variant of the current OpenAI-compatible endpoint.
                                        try {
                                            executeTrackedCall(
                                                ctx = ctx,
                                                stageScope = stageScope,
                                                segmentId = seg.id,
                                                call = client.newCall(reqNonStream),
                                            ) { resp2 ->
                                                heartbeatResponseCode.set(resp2.code)
                                                heartbeatResponseHeadersAtMs.set(System.currentTimeMillis())
                                                val body2 = resp2.body?.string() ?: ""
                                                if (body2.isNotBlank()) {
                                                    respText = respText +
                                                        "\n--- fallback: non-stream chat.completions ---\n" +
                                                    body2
                                                }
                                                if (resp2.isSuccessful && body2.isNotBlank()) {
                                                    try {
                                                        val piece2 =
                                                            extractTextFromOpenAiCompatibleBody(
                                                                body2,
                                                            )
                                                        logStructuredRequest(
                                                            "AIREQ FALLBACK_CHAT_PARSE id=$requestId body_len=${body2.length} content_len=${piece2.length} preview=${truncateForLog(body2, 400)}",
                                                        )
                                                        if (piece2.isNotBlank()) {
                                                            outputText = piece2
                                                        }
                                                    } catch (_: Exception) {
                                                    }
                                                }
                                            }
                                        } catch (e: Exception) {
                                            maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                                            try { FileLogger.w(TAG, "非流式回退失败(OpenAI兼容)：${e.message}") } catch (_: Exception) {}
                                        }
                                    }

                                    if (outputText.isBlank() && allowResponsesFallback) {
                                        heartbeatPhase.set("/responses 回退")
                                        heartbeatResponseCode.set(-1)
                                        heartbeatResponseHeadersAtMs.set(0L)
                                        heartbeatLastEventAtMs.set(0L)
                                        heartbeatEventCount.set(0)
                                        reportDynamicAiFallback(
                                            stageReporter = stageReporter,
                                            stageScope = stageScope,
                                            segmentId = seg.id,
                                            detail = "非流式 ${primaryOpenAiLabel} 回退后仍无正文，继续尝试 /v1/responses；requestId=$requestId",
                                        )
                                        // Some relays only implement multimodal reliably on /v1/responses.
                                        try {
                                            val reqResponses = buildReq(
                                                responsesUrl,
                                                buildResponsesBody(false),
                                                "application/json",
                                            )
                                            executeTrackedCall(
                                                ctx = ctx,
                                                stageScope = stageScope,
                                                segmentId = seg.id,
                                                call = client.newCall(reqResponses),
                                            ) { resp3 ->
                                                heartbeatResponseCode.set(resp3.code)
                                                heartbeatResponseHeadersAtMs.set(System.currentTimeMillis())
                                                val body3 = resp3.body?.string() ?: ""
                                                if (body3.isNotBlank()) {
                                                    respText =
                                                        respText +
                                                        "\n--- fallback: non-stream /responses ---\n" +
                                                        body3
                                                }
                                                if (resp3.isSuccessful && body3.isNotBlank()) {
                                                    try {
                                                        val piece3 =
                                                            extractTextFromOpenAiCompatibleBody(
                                                                body3,
                                                            )
                                                        logStructuredRequest(
                                                            "AIREQ FALLBACK_RESPONSES_PARSE id=$requestId body_len=${body3.length} content_len=${piece3.length} preview=${truncateForLog(body3, 400)}",
                                                        )
                                                        if (piece3.isNotBlank()) {
                                                            outputText = piece3
                                                        }
                                                    } catch (_: Exception) {
                                                    }
                                                }
                                            }
                                        } catch (e: Exception) {
                                            maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                                            try { FileLogger.w(TAG, "Responses 回退失败(OpenAI兼容)：${e.message}") } catch (_: Exception) {}
                                        }
                                    } else if (outputText.isBlank() && !preferResponsesApi) {
                                        reportDynamicAiFallback(
                                            stageReporter = stageReporter,
                                            stageScope = stageScope,
                                            segmentId = seg.id,
                                            detail =
                                                "非流式 ${primaryOpenAiLabel} 回退后仍无正文；已跳过 /v1/responses（当前服务未显式启用 Responses 接口）",
                                        )
                                    }

                                    // If still blank, treat as failure and retry the whole request.
                                    if (outputText.isBlank()) {
                                        lastBody = respText
                                        finished = attempt + 1 >= maxAttempts
                                    } else {
                                        finished = true
                                    }
                                }
                            } else {
                                lastBody = resp.body?.string()
                                val shouldRetry = resp.code >= 500
                                try { FileLogger.w(TAG, "AI 请求失败(OpenAI兼容)：code=${resp.code} 尝试=${attempt + 1}/${maxAttempts} body=${truncateForLog(lastBody ?: "", 800)}") } catch (_: Exception) {}
                                try { FileLogger.w(TAG, "AI 请求失败(OpenAI兼容)：code=${resp.code} 尝试=${attempt + 1}/${maxAttempts} body=${truncateForLog(lastBody ?: "", 800)}") } catch (_: Exception) {}
                                try { OutputFileLogger.error(ctx, TAG, "AI 请求失败(OpenAI兼容)：code=${resp.code} 尝试=${attempt + 1}/${maxAttempts} body=${truncateForLog(lastBody ?: "", 800)}") } catch (_: Exception) {}
                                logStructuredRequest("AIREQ ERR id=$requestId kind=http code=${resp.code} attempt=${attempt + 1}/${maxAttempts}")
                                if (!shouldRetry) throw IllegalStateException("Request failed: ${resp.code} ${lastBody}")
                            }
                        }
                        if (finished) break
                    } catch (e: java.net.SocketTimeoutException) {
                        maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                        lastFailure = e
                        lastFailureKind = "timeout"
                        try { FileLogger.w(TAG, "AI 请求超时(OpenAI) 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                        try { FileLogger.w(TAG, "AI 请求超时(OpenAI) 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                        try { OutputFileLogger.error(ctx, TAG, "AI 请求超时(OpenAI) 尝试=${attempt + 1}/${maxAttempts}") } catch (_: Exception) {}
                        logStructuredRequest("AIREQ ERR id=$requestId kind=timeout attempt=${attempt + 1}/${maxAttempts}")
                        // 继续重试
                    } catch (e: java.io.InterruptedIOException) {
                        maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                        lastFailure = e
                        lastFailureKind =
                            if ((e.message ?: "").contains("timeout", ignoreCase = true)) {
                                "timeout"
                            } else {
                                "interrupted"
                            }
                        try { FileLogger.w(TAG, "AI 请求中断(OpenAI) 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        try { OutputFileLogger.error(ctx, TAG, "AI 请求中断(OpenAI) 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        logStructuredRequest("AIREQ ERR id=$requestId kind=interrupted attempt=${attempt + 1}/${maxAttempts}")
                    } catch (e: Exception) {
                        maybeThrowDynamicAiCancelled(ctx, stageScope, seg.id)
                        lastFailure = e
                        lastFailureKind = "exception"
                        try { FileLogger.w(TAG, "AI 请求异常(OpenAI) 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        try { FileLogger.w(TAG, "AI 请求异常(OpenAI) 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        try { OutputFileLogger.error(ctx, TAG, "AI 请求异常(OpenAI) 尝试=${attempt + 1}/${maxAttempts}：${e.message}") } catch (_: Exception) {}
                        logStructuredRequest("AIREQ ERR id=$requestId kind=exception attempt=${attempt + 1}/${maxAttempts}")
                    }
                    attempt++
                    if (attempt < maxAttempts) {
                        val backoff = (1000L * (1 shl (attempt - 1))).coerceAtMost(5000L)
                        sleepWithDynamicCancelAwareness(ctx, stageScope, seg.id, backoff)
                    } else if (lastCode >= 0) {
                        throw IllegalStateException("Request failed: ${lastCode} ${lastBody}")
                    } else if (lastFailure != null) {
                        throw IllegalStateException(
                            buildAiTerminalFailureMessage(
                                lastFailureKind = lastFailureKind,
                                lastFailure = lastFailure,
                                maxAttempts = maxAttempts,
                                requestTimeoutMs = requestTimeoutMs,
                            ),
                        )
                    } else {
                        throw IllegalStateException("Request failed: unknown error")
                    }
                }
            }
            try {
                FileLogger.d(TAG, "AI 响应长度(OpenAI兼容)=${respText.length}")
                val preview = truncateForLog(respText, 2000)
                FileLogger.i(TAG, "AI 响应预览(OpenAI)：${preview}")
            } catch (_: Exception) {}
            try {
                val preview = truncateForLog(respText, 2000)
                FileLogger.i(TAG, "AI 响应预览(OpenAI)：${preview}")
            } catch (_: Exception) {}
            // 完整响应落盘（分块写入）
            try {
                logStructuredRequest("AIREQ RESP_BODY_BEGIN id=$requestId")
                OutputFileLogger.info(ctx, TAG, "AI 响应完整内容(OpenAI) 开始 >>>")
                val text2 = respText
                val chunk2 = 1800
                var j = 0
                while (j < text2.length) {
                    val end = kotlin.math.min(j + chunk2, text2.length)
                    OutputFileLogger.info(ctx, TAG, text2.substring(j, end))
                    j = end
                }
                OutputFileLogger.info(ctx, TAG, "AI 响应完整内容(OpenAI) 结束 <<<")
                logStructuredRequest("AIREQ RESP_BODY_END id=$requestId")
            } catch (_: Exception) {}
            try {
                val preview = truncateForLog(respText, 2000)
                OutputFileLogger.info(ctx, TAG, "AI 响应预览(OpenAI)：${preview}")
            } catch (_: Exception) {}
            // 若无正常内容且响应体包含 error，则回落为直接保存错误预览，供前端显示
            if (outputText.isBlank()) {
                if (strictFailure) {
                    throw IllegalStateException(
                        buildAiPayloadFailureMessage("OpenAI兼容", respText),
                    )
                }
                try {
                    val low = respText.lowercase()
                    outputText = when {
                        low.contains("\"error\"") || low.contains("no candidates returned") -> {
                            "AI response preview(OpenAI): " + respText
                        }
                        respText.isNotBlank() -> {
                            "AI empty content(OpenAI), raw response: " + truncateForLog(respText, 2000)
                        }
                        else -> "AI empty response(OpenAI)"
                    }
                } catch (_: Exception) {}
            }
            val (structured, cats) = extractJsonBlocks(outputText)
            // 结构化 JSON 完整输出（Pretty JSON + 分块）
            try {
                if (structured != null && structured.trim().isNotEmpty()) {
                    var pretty = structured
                    try {
                        val jo = JSONObject(structured)
                        pretty = jo.toString(2)
                    } catch (_: Exception) {
                        try {
                            val ja = JSONArray(structured)
                            pretty = ja.toString(2)
                        } catch (_: Exception) {}
                    }
                    OutputFileLogger.info(ctx, TAG, "AI structured_json(OpenAI) 开始 >>>")
                    val textSJ2 = pretty
                    val chunkSJ2 = 1800
                    var q = 0
                    while (q < textSJ2.length) {
                        val end = kotlin.math.min(q + chunkSJ2, textSJ2.length)
                        OutputFileLogger.info(ctx, TAG, textSJ2.substring(q, end))
                        q = end
                    }
                    OutputFileLogger.info(ctx, TAG, "AI structured_json(OpenAI) 结束 <<<")
                } else {
                    OutputFileLogger.info(ctx, TAG, "AI structured_json(OpenAI) 为空")
                }
                if (cats != null && cats.trim().isNotEmpty()) {
                    OutputFileLogger.info(ctx, TAG, "AI 分类(OpenAI)：${cats}")
                }
            } catch (_: Exception) {}
            logStructuredRequest("AIREQ DONE id=$requestId content_len=${outputText.length} response_len=${respText.length}")
            return finalizeAiResultJson(
                ctx = ctx,
                seg = seg,
                samples = effSamples,
                prompt = prompt,
                isMerge = isMerge,
                injectDynamicRules = injectDynamicRules,
                maxImagesOverride = maxImagesOverride,
                allowJsonAutoRetry = allowJsonAutoRetry,
                jsonRetryCount = jsonRetryCount,
                aiConfigOverride = aiConfigOverride,
                strictFailure = strictFailure,
                model = model,
                outputText = outputText,
                structured = structured,
                categories = cats,
                rawRequest = rawRequestTrace,
                rawResponse = respText,
                stageReporter = stageReporter,
                stageScope = stageScope,
            )
            }
        } finally {
            heartbeatStop.set(true)
            try {
                heartbeatTimer?.cancel()
            } catch (_: Exception) {}
        }
    }

    private data class AiImagePayload(
        val bytes: ByteArray,
        val mime: String,
    )

    private fun resolveAiImageSendFormat(ctx: Context): String {
        val raw = try {
            UserSettingsStorage.getString(
                ctx,
                UserSettingsKeysNative.AI_IMAGE_SEND_FORMAT,
                "original"
            )
        } catch (_: Exception) {
            "original"
        }
        return when (raw?.trim()?.lowercase()) {
            "jpg", "jpeg" -> "jpeg"
            "png" -> "png"
            else -> "original"
        }
    }

    /**
     * AI 发送前按全局设置临时转码，不修改本地截图文件。
     * JPEG 在启用“目标大小”时沿用目标 KB，避免兼容转换后请求体过大。
     */
    private fun prepareImagePayloadForAi(ctx: Context, filePath: String): AiImagePayload? {
        val originalBytes = try { File(filePath).readBytes() } catch (_: Exception) { null }
            ?: return null
        if (originalBytes.isEmpty()) return null

        val sendFormat = resolveAiImageSendFormat(ctx)
        val originalMime = guessMime(filePath)
        if (sendFormat == "original") {
            return AiImagePayload(originalBytes, originalMime)
        }
        if (sendFormat == "jpeg" && originalMime == "image/jpeg") {
            return AiImagePayload(originalBytes, originalMime)
        }
        if (sendFormat == "png" && originalMime == "image/png") {
            return AiImagePayload(originalBytes, originalMime)
        }

        val bitmap = try { BitmapFactory.decodeFile(filePath) } catch (_: Exception) { null }
            ?: return AiImagePayload(originalBytes, originalMime)
        return try {
            when (sendFormat) {
                "jpeg" -> {
                    val bytes = encodeJpegForAi(ctx, bitmap)
                        ?: return AiImagePayload(originalBytes, originalMime)
                    AiImagePayload(bytes, "image/jpeg")
                }
                "png" -> {
                    val bytes = compressBitmapForAi(bitmap, Bitmap.CompressFormat.PNG, 100)
                        ?: return AiImagePayload(originalBytes, originalMime)
                    AiImagePayload(bytes, "image/png")
                }
                else -> AiImagePayload(originalBytes, originalMime)
            }
        } finally {
            try { bitmap.recycle() } catch (_: Exception) {}
        }
    }

    private fun encodeJpegForAi(ctx: Context, bitmap: Bitmap): ByteArray? {
        val useTargetSize = try {
            UserSettingsStorage.getBoolean(
                ctx,
                UserSettingsKeysNative.USE_TARGET_SIZE,
                false
            )
        } catch (_: Exception) {
            false
        }
        if (useTargetSize) {
            val targetKb = try {
                UserSettingsStorage.getInt(
                    ctx,
                    UserSettingsKeysNative.TARGET_SIZE_KB,
                    50
                ).coerceIn(50, 20 * 1024)
            } catch (_: Exception) {
                50
            }
            val targetBytes = (targetKb * 1024).coerceAtLeast(1024)
            return compressBitmapToTargetForAi(
                bitmap,
                Bitmap.CompressFormat.JPEG,
                targetBytes,
                minQuality = 1,
                maxQuality = 100,
            ) ?: compressBitmapForAi(bitmap, Bitmap.CompressFormat.JPEG, 85)
        }
        return compressBitmapForAi(bitmap, Bitmap.CompressFormat.JPEG, 90)
    }

    private fun compressBitmapForAi(
        bitmap: Bitmap,
        format: Bitmap.CompressFormat,
        quality: Int,
    ): ByteArray? {
        return try {
            val out = ByteArrayOutputStream()
            bitmap.compress(format, quality.coerceIn(1, 100), out)
            out.toByteArray()
        } catch (_: Exception) {
            null
        }
    }

    private fun compressBitmapToTargetForAi(
        bitmap: Bitmap,
        format: Bitmap.CompressFormat,
        targetBytes: Int,
        minQuality: Int,
        maxQuality: Int,
    ): ByteArray? {
        var lo = minQuality.coerceIn(1, 100)
        var hi = maxQuality.coerceIn(lo, 100)
        var bestUnder: ByteArray? = null
        var bestOver: ByteArray? = null
        var iterations = 0
        while (lo <= hi && iterations < 12) {
            iterations++
            val mid = (lo + hi) / 2
            val data = compressBitmapForAi(bitmap, format, mid) ?: return null
            if (data.size <= targetBytes) {
                if (bestUnder == null || data.size > bestUnder!!.size) {
                    bestUnder = data
                }
                lo = mid + 1
            } else {
                if (bestOver == null || data.size < bestOver!!.size) {
                    bestOver = data
                }
                hi = mid - 1
            }
        }
        return bestUnder ?: bestOver
    }

    internal fun guessMime(path: String): String {
        val lower = path.lowercase()
        return when {
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
            lower.endsWith(".png") -> "image/png"
            lower.endsWith(".webp") -> "image/webp"
            lower.endsWith(".gif") -> "image/gif"
            lower.endsWith(".bmp") -> "image/bmp"
            lower.endsWith(".heic") -> "image/heic"
            lower.endsWith(".heif") -> "image/heif"
            lower.endsWith(".avif") -> "image/avif"
            else -> "image/png"
        }
    }

    private fun isDamagedImageFile(filePath: String): Boolean {
        if (filePath.isBlank()) return true
        val f = try { File(filePath) } catch (_: Exception) { return true }
        val ok = try { f.exists() && f.length() > 0L } catch (_: Exception) { false }
        if (!ok) return true
        return try {
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(filePath, opts)
            opts.outWidth <= 0 || opts.outHeight <= 0
        } catch (_: Exception) { true }
    }


    internal fun extractJsonBlocks(text: String): Pair<String?, String?> {
        // 尝试提取 JSON；若存在 categories 字段则单独返回其字符串表示
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        if (start >= 0 && end > start) {
            val json = text.substring(start, end + 1)
            return try {
                val obj = JSONObject(json)
                val cats = obj.optJSONArray("categories")?.toString()
                Pair(json, cats)
            } catch (_: Exception) {
                Pair(json, null)
            }
        }
        return Pair(null, null)
    }


    private fun SegmentSummaryManager.finalizeAiResultJson(
        ctx: Context,
        seg: SegmentDatabaseHelper.Segment,
        samples: List<SegmentDatabaseHelper.Sample>,
        prompt: String,
        isMerge: Boolean,
        injectDynamicRules: Boolean,
        maxImagesOverride: Int?,
        allowJsonAutoRetry: Boolean,
        jsonRetryCount: Int,
        aiConfigOverride: AISettingsNative.AIConfig?,
        strictFailure: Boolean,
        model: String,
        outputText: String,
        structured: String?,
        categories: String?,
        rawRequest: String?,
        rawResponse: String?,
        stageReporter: ((String, String, String, Long) -> Unit)?,
        stageScope: String?,
    ): AiCallResult {
        val parsedStructured = parseStructuredJsonObject(structured)
        if (parsedStructured != null) {
            val withMeta = applyJsonFixMeta(
                parsedStructured,
                JsonFixMeta(
                    retryCount = jsonRetryCount,
                    jsonFix = if (jsonRetryCount > 0) "retry_success" else "none",
                    needsManualRetry = false,
                    retryMessage = ""
                )
            )
            val cats = pickNonEmpty(categories, withMeta.optJSONArray("categories")?.toString())
            return AiCallResult(
                model = model,
                outputText = outputText,
                structuredJson = withMeta.toString(),
                categories = if (cats.isNotEmpty()) cats else null,
                rawRequest = rawRequest,
                rawResponse = rawResponse
            )
        }

        val repaired = repairStructuredJson(outputText)
        if (repaired != null) {
            try {
                val obj = JSONObject(repaired)
                val withMeta = applyJsonFixMeta(
                    obj,
                    JsonFixMeta(
                        retryCount = jsonRetryCount,
                        jsonFix = "repaired",
                        needsManualRetry = false,
                        retryMessage = ""
                    )
                )
                val cats = pickNonEmpty(categories, withMeta.optJSONArray("categories")?.toString())
                return AiCallResult(
                    model = model,
                    outputText = outputText,
                    structuredJson = withMeta.toString(),
                    categories = if (cats.isNotEmpty()) cats else null,
                    rawRequest = rawRequest,
                    rawResponse = rawResponse
                )
            } catch (_: Exception) {
            }
        }

        val maxAutoRetry = readSegmentsJsonAutoRetryMax(ctx)
        if (allowJsonAutoRetry && maxAutoRetry > 0 && jsonRetryCount < maxAutoRetry) {
            try {
                FileLogger.w(TAG, "structured_json 无法解析，触发自动重试 seg=${seg.id}")
            } catch (_: Exception) {
            }
            reportDynamicAiJsonRetry(
                stageReporter = stageReporter,
                stageScope = stageScope,
                segmentId = seg.id,
                detail = "structured_json 无法解析，开始第 ${jsonRetryCount + 1}/${maxAutoRetry} 次自动修复重试",
            )
            val repairPrompt = buildJsonRepairRetryPrompt(prompt, outputText)
            return callGeminiWithImages(
                ctx = ctx,
                seg = seg,
                samples = samples,
                prompt = repairPrompt,
                isMerge = isMerge,
                injectDynamicRules = injectDynamicRules,
                maxImagesOverride = maxImagesOverride,
                allowJsonAutoRetry = allowJsonAutoRetry,
                jsonRetryCount = jsonRetryCount + 1,
                aiConfigOverride = aiConfigOverride,
                strictFailure = strictFailure,
                stageReporter = stageReporter,
                stageScope = stageScope,
            )
        }

        val fallback = JSONObject()
        applyJsonFixMeta(
            fallback,
            JsonFixMeta(
                retryCount = jsonRetryCount,
                jsonFix = "retry_failed",
                needsManualRetry = true,
                retryMessage = "自动重试后仍未获得完整结构化结果，请手动重试。"
            )
        )
        return AiCallResult(
            model = model,
            outputText = outputText,
            structuredJson = fallback.toString(),
            categories = categories,
            rawRequest = rawRequest,
            rawResponse = rawResponse
        )
    }
