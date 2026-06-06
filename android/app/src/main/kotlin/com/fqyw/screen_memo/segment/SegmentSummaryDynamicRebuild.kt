package com.fqyw.screen_memo.segment

import android.content.Context
import com.fqyw.screen_memo.database.SegmentDatabaseHelper
import com.fqyw.screen_memo.settings.AISettingsNative

internal typealias DynamicRebuildStepException = SegmentSummaryManager.DynamicRebuildStepException
internal typealias DynamicRebuildCancelledException = SegmentSummaryManager.DynamicRebuildCancelledException

internal fun SegmentSummaryManager.rebuildWindowStrictInternal(
    ctx: Context,
    windowStart: Long,
    windowEnd: Long,
    durationSec: Int,
    sampleIntervalSec: Int,
    aiConfig: AISettingsNative.AIConfig,
    existingSegmentId: Long = 0L,
    stageReporter: ((String, String, String, Long) -> Unit)? = null,
): Long {
    val appCtx = try { ctx.applicationContext } catch (_: Exception) { ctx }
    var seg: SegmentDatabaseHelper.Segment? = null
    var summaryReady = false
    var outputText: String? = null
    var structuredJson: String? = null
    try {
        logBackfillDiag(
            appCtx,
            "rebuildWindowStrict enter window=${fmt(windowStart)}-${fmt(windowEnd)}($windowStart-$windowEnd) " +
                "durationSec=$durationSec sampleIntervalSec=$sampleIntervalSec existingSegmentId=$existingSegmentId " +
                "model=${aiConfig.model}",
        )
        stageReporter?.invoke(
            "window_enter",
            "进入重建时间窗",
            "${fmt(windowStart)} - ${fmt(windowEnd)}",
            existingSegmentId,
        )
        if (existingSegmentId > 0L) {
            val existing = SegmentDatabaseHelper.getSegmentById(appCtx, existingSegmentId)
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict existingLookup requested=$existingSegmentId found=${existing != null} " +
                    (existing?.let { "seg=${it.id} ${fmt(it.startTime)}-${fmt(it.endTime)} status=${it.status}" } ?: ""),
            )
            if (existing != null) {
                if (existing.startTime != windowStart || existing.endTime != windowEnd) {
                    logBackfillDiag(
                        appCtx,
                        "rebuildWindowStrict existingMismatch requested=$existingSegmentId " +
                            "existingWindow=${fmt(existing.startTime)}-${fmt(existing.endTime)} current=${fmt(windowStart)}-${fmt(windowEnd)}",
                    )
                    stageReporter?.invoke(
                        "window_existing_mismatch",
                        "忽略旧续跑段落",
                        "续跑段落 #${existing.id} 与当前时间窗不一致，改为按当前窗口处理",
                        existing.id,
                    )
                } else {
                    val existingResult = SegmentDatabaseHelper.getResultForSegment(appCtx, existing.id)
                    val repairReason = resultRepairReason(existingResult.first, existingResult.second)
                    logBackfillDiag(
                        appCtx,
                        "rebuildWindowStrict existingResult seg=${existing.id} reason=$repairReason " +
                            "hasUsable=${_hasUsableSegmentResult(existingResult.first, existingResult.second)} " +
                            "needsRepair=${SegmentDatabaseHelper.needsDynamicSummaryRepair(existingResult.first, existingResult.second)}",
                    )
                    if (!SegmentDatabaseHelper.needsDynamicSummaryRepair(existingResult.first, existingResult.second)) {
                        seg = existing
                        summaryReady = true
                        outputText = existingResult.first
                        structuredJson = existingResult.second
                        logBackfillDiag(
                            appCtx,
                            "rebuildWindowStrict reuseExisting seg=${existing.id} reason=compliant_result",
                        )
                        stageReporter?.invoke(
                            "window_reuse_existing",
                            "复用已有结果",
                            "已复用段落 #${existing.id} 的现有结果",
                            existing.id,
                        )
                    } else if (_hasUsableSegmentResult(existingResult.first, existingResult.second)) {
                        seg = existing
                        logBackfillDiag(
                            appCtx,
                            "rebuildWindowStrict regenerateExisting seg=${existing.id} reason=$repairReason",
                        )
                        stageReporter?.invoke(
                            "window_repair_bad_json",
                            "Regenerate invalid JSON",
                            "Segment #${existing.id} has an unusable structured_json result. Regenerating the AI summary.",
                            existing.id,
                        )
                    } else {
                        seg = existing
                        logBackfillDiag(
                            appCtx,
                            "rebuildWindowStrict continueExistingNoSummary seg=${existing.id} reason=$repairReason",
                        )
                        stageReporter?.invoke(
                            "window_reuse_no_summary",
                            "复用待总结动态",
                            "段落 #${existing.id} 已存在但缺少总结，继续生成 AI 总结",
                            existing.id,
                        )
                    }
                }
            }
        }

        if (seg == null) {
            val exactId = SegmentDatabaseHelper.findSegmentIdByWindow(appCtx, windowStart, windowEnd)
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict exactLookup window=${fmt(windowStart)}-${fmt(windowEnd)} exactId=$exactId",
            )
            if (exactId > 0L) {
                val exactSeg = SegmentDatabaseHelper.getSegmentById(appCtx, exactId)
                val exactResult = SegmentDatabaseHelper.getResultForSegment(appCtx, exactId)
                val repairReason = resultRepairReason(exactResult.first, exactResult.second)
                logBackfillDiag(
                    appCtx,
                    "rebuildWindowStrict exactResult exactId=$exactId found=${exactSeg != null} reason=$repairReason " +
                        "hasUsable=${_hasUsableSegmentResult(exactResult.first, exactResult.second)} " +
                        "needsRepair=${SegmentDatabaseHelper.needsDynamicSummaryRepair(exactResult.first, exactResult.second)}",
                )
                if (exactSeg != null && !SegmentDatabaseHelper.needsDynamicSummaryRepair(exactResult.first, exactResult.second)) {
                    seg = exactSeg
                    summaryReady = true
                    outputText = exactResult.first
                    structuredJson = exactResult.second
                    logBackfillDiag(
                        appCtx,
                        "rebuildWindowStrict reuseExact seg=${exactSeg.id} reason=compliant_result",
                    )
                    stageReporter?.invoke(
                        "window_reuse_exact",
                        "复用时间窗结果",
                        "发现完全匹配时间窗的已有结果，直接复用",
                        exactSeg.id,
                    )
                } else if (exactSeg != null && _hasUsableSegmentResult(exactResult.first, exactResult.second)) {
                    seg = exactSeg
                    logBackfillDiag(
                        appCtx,
                        "rebuildWindowStrict regenerateExact seg=${exactSeg.id} reason=$repairReason",
                    )
                    stageReporter?.invoke(
                        "window_repair_exact_bad_json",
                        "Regenerate invalid JSON",
                        "Exact segment #${exactSeg.id} has an unusable structured_json result. Regenerating the AI summary.",
                        exactSeg.id,
                    )
                } else if (exactSeg != null) {
                    seg = exactSeg
                    logBackfillDiag(
                        appCtx,
                        "rebuildWindowStrict continueExactNoSummary seg=${exactSeg.id} reason=$repairReason",
                    )
                    stageReporter?.invoke(
                        "window_reuse_exact_no_summary",
                        "复用待总结窗口",
                        "发现完全匹配时间窗的段落 #${exactSeg.id}，继续生成 AI 总结",
                        exactSeg.id,
                    )
                } else {
                    logBackfillDiag(
                        appCtx,
                        "rebuildWindowStrict cleanupDanglingExact exactId=$exactId reason=getSegmentById_null",
                    )
                    cleanupRebuildSegment(appCtx, exactId)
                }
            }
        }

        if (seg == null) {
            if (!ensureNoRootOverlapBeforeCreate(appCtx, windowStart, windowEnd, "rebuildWindowStrict")) {
                logBackfillDiag(
                    appCtx,
                    "rebuildWindowStrict skipCreate reason=root_overlap window=${fmt(windowStart)}-${fmt(windowEnd)}",
                )
                stageReporter?.invoke(
                    "window_skip_overlap",
                    "跳过交错窗口",
                    "当前时间窗已被其它顶层动态覆盖或交错，已跳过创建",
                    0L,
                )
                return 0L
            }
            stageReporter?.invoke(
                "window_create_segment",
                "创建动态事件",
                "正在为当前时间窗创建新的动态记录",
                0L,
            )
            val createdId = SegmentDatabaseHelper.createSegment(
                appCtx,
                windowStart,
                windowEnd,
                durationSec.coerceAtLeast(60),
                sampleIntervalSec.coerceAtLeast(5),
                status = "collecting",
            )
            if (createdId <= 0L) {
                logBackfillDiag(
                    appCtx,
                    "rebuildWindowStrict createFailed window=${fmt(windowStart)}-${fmt(windowEnd)} createdId=$createdId",
                )
                throw DynamicRebuildStepException("创建动态事件失败", 0L)
            }
            seg = SegmentDatabaseHelper.getSegmentById(appCtx, createdId)
                ?: SegmentDatabaseHelper.Segment(
                    id = createdId,
                    startTime = windowStart,
                    endTime = windowEnd,
                    durationSec = durationSec.coerceAtLeast(60),
                    sampleIntervalSec = sampleIntervalSec.coerceAtLeast(5),
                    status = "collecting",
                )
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict createdSegment seg=${seg.id} window=${fmt(seg.startTime)}-${fmt(seg.endTime)} status=${seg.status}",
            )
            stageReporter?.invoke(
                "window_segment_ready",
                "动态事件已创建",
                "段落 #${seg.id} 已创建，准备装载样本",
                seg.id,
            )
        }

        stageReporter?.invoke(
            "window_load_samples",
            "读取现有样本",
            "检查段落 #${seg.id} 是否已有样本图片",
            seg.id,
        )
        var samples = SegmentDatabaseHelper.getSamplesForSegment(appCtx, seg.id)
        logBackfillDiag(
            appCtx,
            "rebuildWindowStrict samplesInitial seg=${seg.id} count=${samples.size} summaryReady=$summaryReady",
        )
        if (!summaryReady && samples.isEmpty()) {
            val shotCount = try {
                SegmentDatabaseHelper.countShotsBetween(appCtx, windowStart, windowEnd, hardLimit = 1)
            } catch (_: Exception) {
                0
            }
            if (shotCount <= 0) {
                logBackfillDiag(
                    appCtx,
                    "rebuildWindowStrict skipNoSourceShots seg=${seg.id} window=${fmt(windowStart)}-${fmt(windowEnd)} reason=no_screenshots_in_window",
                )
                try { SegmentDatabaseHelper.updateSegmentStatus(appCtx, seg.id, "completed") } catch (_: Exception) {}
                stageReporter?.invoke(
                    "window_skip_no_samples",
                    "跳过无样本窗口",
                    "当前时间窗没有截图样本，无法重新生成 AI 总结",
                    seg.id,
                )
                return seg.id
            }
        }
        if (samples.isEmpty()) {
            val effectiveDurationSec =
                (((windowEnd - windowStart) / 1000L).toInt()).coerceAtLeast(1)
            val effectiveSampleIntervalSec = sampleIntervalSec.coerceAtLeast(5)
            val buildSeg = if (
                seg.startTime == windowStart &&
                seg.endTime == windowEnd &&
                seg.durationSec == effectiveDurationSec &&
                seg.sampleIntervalSec == effectiveSampleIntervalSec
            ) {
                seg
            } else {
                seg.copy(
                    startTime = windowStart,
                    endTime = windowEnd,
                    durationSec = effectiveDurationSec,
                    sampleIntervalSec = effectiveSampleIntervalSec,
                )
            }
            samples = buildSamplesForSegment(appCtx, buildSeg)
            if (samples.isNotEmpty()) {
                SegmentDatabaseHelper.saveSamples(appCtx, seg.id, samples)
            }
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict samplesBuilt seg=${seg.id} count=${samples.size} " +
                    "effectiveDurationSec=$effectiveDurationSec effectiveSampleIntervalSec=$effectiveSampleIntervalSec",
            )
            stageReporter?.invoke(
                "window_samples_built",
                "样本构建完成",
                "为段落 #${seg.id} 构建了 ${samples.size} 张样本图片",
                seg.id,
            )
        } else {
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict samplesReuse seg=${seg.id} count=${samples.size}",
            )
            stageReporter?.invoke(
                "window_samples_ready",
                "样本已就绪",
                "段落 #${seg.id} 复用 ${samples.size} 张现有样本",
                seg.id,
            )
        }

        if (!summaryReady) {
            ensureDynamicRebuildNotCancelled(appCtx, seg.id)
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict summarizeStart seg=${seg.id} samples=${samples.size}",
            )
            val summary = summarizeSegmentForRebuildStrict(
                appCtx,
                seg,
                samples,
                aiConfig,
                stageReporter = stageReporter,
            )
            outputText = summary.first
            structuredJson = summary.second
            summaryReady = true
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict summarizeDone seg=${seg.id} " +
                    "hasUsable=${_hasUsableSegmentResult(outputText, structuredJson)} " +
                    "repairReason=${resultRepairReason(outputText, structuredJson)}",
            )
        } else {
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict summarizeSkipped seg=${seg.id} reason=summaryReady",
            )
        }

        if (_hasUsableSegmentResult(outputText, structuredJson)) {
            ensureDynamicRebuildNotCancelled(appCtx, seg.id)
            val latestSeg = SegmentDatabaseHelper.getSegmentById(appCtx, seg.id) ?: seg
            val latestSamples = SegmentDatabaseHelper.getSamplesForSegment(appCtx, latestSeg.id)
                .ifEmpty { samples }
            stageReporter?.invoke(
                "window_merge_check",
                "检查向前合并",
                "总结已生成，准备判断是否需要与上一条动态合并",
                latestSeg.id,
            )
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict mergeCheckStart seg=${latestSeg.id} samples=${latestSamples.size} " +
                    "repairReason=${resultRepairReason(outputText, structuredJson)}",
            )
            tryCompareAndMergeBackwardStrict(
                appCtx,
                latestSeg,
                latestSamples,
                outputText ?: "",
                structuredJson,
                aiConfig,
                stageReporter = stageReporter,
            )
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict mergeCheckDone seg=${latestSeg.id}",
            )
        } else {
            logBackfillDiag(
                appCtx,
                "rebuildWindowStrict noUsableResult seg=${seg.id} action=mark_completed_without_merge",
            )
            try { SegmentDatabaseHelper.updateSegmentStatus(appCtx, seg.id, "completed") } catch (_: Exception) {}
        }
        stageReporter?.invoke(
            "window_done",
            "当前时间窗完成",
            "段落 #${seg.id} 已完成重建",
            seg.id,
        )
        logBackfillDiag(
            appCtx,
            "rebuildWindowStrict done seg=${seg.id} summaryReady=$summaryReady " +
                "hasUsable=${_hasUsableSegmentResult(outputText, structuredJson)}",
        )
        return seg.id
    } catch (e: DynamicRebuildCancelledException) {
        logBackfillDiag(
            appCtx,
            "rebuildWindowStrict cancelled seg=${seg?.id ?: 0L} message=${e.message ?: e.toString()}",
        )
        throw e
    } catch (e: DynamicRebuildStepException) {
        if (!summaryReady) {
            seg?.id?.takeIf { it > 0L }?.let {
                logBackfillDiag(appCtx, "rebuildWindowStrict cleanupAfterStepException seg=$it reason=summary_not_ready")
                cleanupRebuildSegment(appCtx, it)
            }
        }
        logBackfillDiag(
            appCtx,
            "rebuildWindowStrict stepException seg=${seg?.id ?: 0L} summaryReady=$summaryReady " +
                "message=${e.message ?: e.toString()}",
        )
        throw e
    } catch (e: Exception) {
        if (!summaryReady) {
            seg?.id?.takeIf { it > 0L }?.let {
                logBackfillDiag(appCtx, "rebuildWindowStrict cleanupAfterException seg=$it reason=summary_not_ready")
                cleanupRebuildSegment(appCtx, it)
            }
        }
        logBackfillDiag(
            appCtx,
            "rebuildWindowStrict exception seg=${seg?.id ?: 0L} summaryReady=$summaryReady " +
                "type=${e.javaClass.simpleName} message=${e.message ?: e.toString()}",
        )
        throw DynamicRebuildStepException(
            "动态重建失败：${e.message ?: e.toString()}",
            seg?.id ?: 0L,
        )
    }
}
