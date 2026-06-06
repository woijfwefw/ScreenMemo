package com.fqyw.screen_memo.segment

import android.content.Context
import com.fqyw.screen_memo.database.SegmentDatabaseHelper
import com.fqyw.screen_memo.logging.FileLogger

private const val TAG = "SegmentSummaryManager"

internal typealias ExistingDynamicWindow = SegmentSummaryManager.ExistingDynamicWindow
internal typealias DynamicRebuildWindow = SegmentSummaryManager.DynamicRebuildWindow
internal typealias DynamicWindowPlanResult = SegmentSummaryManager.DynamicWindowPlanResult
internal fun SegmentSummaryManager.buildFullRebuildWorklistInternal(
    ctx: Context,
    durationSec: Int,
    targetDayKey: String? = null,
): List<DynamicRebuildWindow> {
    val safeDurationSec = durationSec.coerceAtLeast(60)
    val normalizedTargetDayKey = targetDayKey?.trim().orEmpty()
    val targetDayBounds = if (normalizedTargetDayKey.isNotBlank()) {
        dayBoundsMillis(normalizedTargetDayKey)
    } else {
        null
    }
    if (normalizedTargetDayKey.isNotBlank() && targetDayBounds == null) {
        logBackfillDiag(
            ctx,
            "buildFullRebuildWorklist empty reason=invalid_target_day targetDayKey=$normalizedTargetDayKey",
        )
        return emptyList()
    }
    val durationMs = safeDurationSec * 1000L
    val shots = if (targetDayBounds != null) {
        SegmentDatabaseHelper.listShotsBetween(
            ctx,
            targetDayBounds.first,
            kotlin.math.min(System.currentTimeMillis(), targetDayBounds.second + durationMs),
            perTableLimit = Int.MAX_VALUE,
        )
    } else {
        SegmentDatabaseHelper.listAllShotsAscending(ctx)
    }
    if (shots.isEmpty()) return emptyList()

    val works = ArrayList<DynamicRebuildWindow>()
    var i = 0
    while (i < shots.size) {
        val start = shots[i].captureTime
        if (targetDayBounds != null && start > targetDayBounds.second) break
        val end = start + durationMs
        works.add(
            DynamicRebuildWindow(
                startTime = start,
                endTime = end,
            ),
        )

        var next = i + 1
        while (next < shots.size && shots[next].captureTime < end) next++
        i = if (next <= i) i + 1 else next
    }
    return works
}
internal fun SegmentSummaryManager.planNonOverlappingWindowsInternal(
    shotTimes: List<Long>,
    existingWindows: List<ExistingDynamicWindow>,
    durationMs: Long,
    nowMillis: Long,
    dayEndMillis: Long? = null,
): DynamicWindowPlanResult {
    val safeDurationMs = durationMs.coerceAtLeast(60_000L)
    val shots = shotTimes.asSequence()
        .filter { it > 0L }
        .distinct()
        .sorted()
        .toList()
    if (shots.isEmpty()) {
        return DynamicWindowPlanResult(emptyList(), skippedCovered = 0, mergedShortGaps = 0)
    }
    val existing = existingWindows
        .filter { it.startTime < it.endTime }
        .sortedWith(compareBy<ExistingDynamicWindow> { it.startTime }.thenBy { it.endTime })
    val out = ArrayList<DynamicRebuildWindow>()
    var skippedCovered = 0
    var mergedShortGaps = 0
    var i = 0
    while (i < shots.size) {
        var start = shots[i]
        if (dayEndMillis != null && start > dayEndMillis) break

        var moved = true
        while (moved) {
            moved = false
            val covering = existing.firstOrNull { it.startTime <= start && it.endTime > start }
            if (covering != null) {
                skippedCovered++
                while (i < shots.size && shots[i] < covering.endTime) i++
                if (i >= shots.size) return DynamicWindowPlanResult(out, skippedCovered, mergedShortGaps)
                start = shots[i]
                if (dayEndMillis != null && start > dayEndMillis) {
                    return DynamicWindowPlanResult(out, skippedCovered, mergedShortGaps)
                }
                moved = true
            }
        }

        var end = start + safeDurationMs
        if (end > nowMillis) break
        val nextOverlap = existing.firstOrNull { it.startTime < end && it.endTime > start }
        if (nextOverlap != null) {
            if (nextOverlap.startTime > start && nextOverlap.startTime - start >= safeDurationMs) {
                end = start + safeDurationMs
            } else {
                mergedShortGaps++
                while (i < shots.size && shots[i] < nextOverlap.endTime) i++
                continue
            }
        }

        if (end <= nowMillis) {
            out.add(DynamicRebuildWindow(startTime = start, endTime = end))
        }
        var next = i + 1
        while (next < shots.size && shots[next] < end) next++
        i = if (next <= i) i + 1 else next
    }
    return DynamicWindowPlanResult(out, skippedCovered, mergedShortGaps)
}

internal fun SegmentSummaryManager.loadExistingRootWindowsInternal(
    ctx: Context,
    startMillis: Long,
    endMillis: Long,
    excludeSegmentId: Long? = null,
): List<ExistingDynamicWindow> {
    return try {
        SegmentDatabaseHelper.listRootSegmentsOverlappingWindow(
            context = ctx,
            startMillis = startMillis,
            endMillis = endMillis,
            excludeSegmentId = excludeSegmentId,
            requireResult = false,
        ).map {
            ExistingDynamicWindow(
                startTime = it.startTime,
                endTime = it.endTime,
                segmentId = it.id,
                hasCompliantResult = SegmentDatabaseHelper.hasCompliantResultForSegment(ctx, it.id),
            )
        }
    } catch (_: Exception) {
        emptyList()
    }
}

internal fun SegmentSummaryManager.firstSafeWindowFromShotsInternal(
    ctx: Context,
    shots: List<SegmentDatabaseHelper.ShotInfo>,
    startIndex: Int,
    durationMs: Long,
    nowMillis: Long,
    dayEndMillis: Long? = null,
): DynamicRebuildWindow? {
    if (startIndex < 0 || startIndex >= shots.size) return null
    val firstShot = shots[startIndex].captureTime
    val scanEnd = (dayEndMillis ?: nowMillis) + durationMs
    val existing = loadExistingRootWindowsInternal(ctx, kotlin.math.max(0L, firstShot - durationMs), scanEnd)
    val plan = planNonOverlappingWindowsInternal(
        shotTimes = shots.drop(startIndex).map { it.captureTime },
        existingWindows = existing,
        durationMs = durationMs,
        nowMillis = nowMillis,
        dayEndMillis = dayEndMillis,
    )
    return plan.windows.firstOrNull()
}

internal fun SegmentSummaryManager.ensureNoRootOverlapBeforeCreateInternal(
    ctx: Context,
    startMillis: Long,
    endMillis: Long,
    source: String,
): Boolean {
    val hasOverlap = try {
        SegmentDatabaseHelper.hasRootSegmentOverlap(ctx, startMillis, endMillis)
    } catch (_: Exception) {
        false
    }
    if (hasOverlap) {
        try {
            FileLogger.i(
                TAG,
                "$source：跳过创建交错窗口 ${fmt(startMillis)} - ${fmt(endMillis)}",
            )
        } catch (_: Exception) {}
    }
    return !hasOverlap
}

internal fun SegmentSummaryManager.getOverlapOrPreviousCompletedSegmentWithResultInternal(
    ctx: Context,
    cur: SegmentDatabaseHelper.Segment,
): SegmentDatabaseHelper.Segment? {
    val overlap = try {
        SegmentDatabaseHelper.listRootSegmentsOverlappingWindow(
            context = ctx,
            startMillis = cur.startTime,
            endMillis = cur.endTime,
            excludeSegmentId = cur.id,
            requireResult = true,
        ).firstOrNull { SegmentDatabaseHelper.hasCompliantResultForSegment(ctx, it.id) }
    } catch (_: Exception) {
        null
    }
    if (overlap != null) return overlap
    return try {
        SegmentDatabaseHelper.getPreviousCompletedSegmentWithResult(ctx, cur.startTime)
            ?.takeIf { SegmentDatabaseHelper.hasCompliantResultForSegment(ctx, it.id) }
    } catch (_: Exception) {
        null
    }
}

internal fun SegmentSummaryManager.buildMissingBackfillWorklistInternal(
    ctx: Context,
    durationSec: Int,
    targetDayKey: String? = null,
): List<DynamicRebuildWindow> {
    val safeDurationSec = durationSec.coerceAtLeast(60)
    val durationMs = safeDurationSec * 1000L
    val normalizedTargetDayKey = targetDayKey?.trim().orEmpty()
    val targetDayBounds = if (normalizedTargetDayKey.isNotBlank()) {
        dayBoundsMillis(normalizedTargetDayKey)
    } else {
        null
    }
    if (normalizedTargetDayKey.isNotBlank() && targetDayBounds == null) {
        logBackfillDiag(
            ctx,
            "buildMissingWorklist empty reason=invalid_target_day targetDayKey=$normalizedTargetDayKey",
        )
        return emptyList()
    }
    val shots = if (targetDayBounds != null) {
        SegmentDatabaseHelper.listShotsBetween(
            ctx,
            targetDayBounds.first,
            kotlin.math.min(System.currentTimeMillis(), targetDayBounds.second + durationMs),
            perTableLimit = Int.MAX_VALUE,
        )
    } else {
        SegmentDatabaseHelper.listAllShotsAscending(ctx)
    }
    logBackfillDiag(
        ctx,
        "buildMissingWorklist start durationSec=$durationSec safeDurationSec=$safeDurationSec " +
            "targetDayKey=${normalizedTargetDayKey.ifBlank { "none" }} shots=${shots.size}",
    )
    if (shots.isEmpty() && targetDayBounds == null) {
        logBackfillDiag(ctx, "buildMissingWorklist empty reason=no_shots")
        return emptyList()
    }
    val now = System.currentTimeMillis()
    val scanStart = targetDayBounds?.first ?: shots.first().captureTime
    val scanEnd = if (targetDayBounds != null) {
        kotlin.math.min(now, targetDayBounds.second + durationMs)
    } else {
        kotlin.math.min(now, shots.last().captureTime + durationMs)
    }
    val scanStartForExisting = kotlin.math.max(0L, scanStart - durationMs)
    logBackfillDiag(
        ctx,
        "buildMissingWorklist scanRange scanStart=${fmt(scanStart)}($scanStart) " +
            "scanEnd=${fmt(scanEnd)}($scanEnd) scanStartForExisting=${fmt(scanStartForExisting)}($scanStartForExisting) " +
            "now=${fmt(now)}($now) " +
            if (shots.isNotEmpty()) {
                "firstShot=${fmt(shots.first().captureTime)} lastShot=${fmt(shots.last().captureTime)}"
            } else {
                "firstShot=none lastShot=none"
            },
    )
    val existingAll = try {
        SegmentDatabaseHelper.listRootSegmentsOverlappingWindow(
            context = ctx,
            startMillis = scanStartForExisting,
            endMillis = scanEnd + durationMs,
            requireResult = false,
        ).map {
            ExistingDynamicWindow(
                startTime = it.startTime,
                endTime = it.endTime,
                segmentId = it.id,
                hasCompliantResult = SegmentDatabaseHelper.hasCompliantResultForSegment(ctx, it.id),
            )
        }
    } catch (e: Exception) {
        logBackfillDiag(
            ctx,
            "buildMissingWorklist existingAll failed type=${e.javaClass.simpleName} message=${e.message ?: e.toString()}",
        )
        emptyList()
    }
    logBackfillDiag(
        ctx,
        "buildMissingWorklist existingAll count=${existingAll.size} compliant=${existingAll.count { it.hasCompliantResult }} " +
            "preview=${existingAll.take(40).joinToString(";") { "seg=${it.segmentId} ${fmt(it.startTime)}-${fmt(it.endTime)} compliant=${it.hasCompliantResult}" }}",
    )
    var existingRawCount = 0
    var existingCompliantCount = 0
    val existingRejectedPreview = ArrayList<String>()
    val existingWithResults = try {
        SegmentDatabaseHelper.listRootSegmentsOverlappingWindow(
            context = ctx,
            startMillis = scanStartForExisting,
            endMillis = scanEnd + durationMs,
            requireResult = true,
        ).mapNotNull {
            existingRawCount += 1
            if (!SegmentDatabaseHelper.hasCompliantResultForSegment(ctx, it.id)) {
                if (existingRejectedPreview.size < 30) {
                    existingRejectedPreview.add(
                        "seg=${it.id} ${fmt(it.startTime)}-${fmt(it.endTime)} reason=non_compliant_result",
                    )
                }
                null
            } else {
                existingCompliantCount += 1
                ExistingDynamicWindow(
                    startTime = it.startTime,
                    endTime = it.endTime,
                    segmentId = it.id,
                    hasCompliantResult = true,
                )
            }
        }
    } catch (e: Exception) {
        logBackfillDiag(
            ctx,
            "buildMissingWorklist existingWithResults failed type=${e.javaClass.simpleName} message=${e.message ?: e.toString()}",
        )
        emptyList()
    }
    logBackfillDiag(
        ctx,
        "buildMissingWorklist existingWithResults raw=$existingRawCount compliant=$existingCompliantCount " +
            "rejectedPreview=${existingRejectedPreview.joinToString(";")}",
    )
    val plan = if (shots.isNotEmpty()) {
            planNonOverlappingWindowsInternal(
            shotTimes = shots.map { it.captureTime },
            existingWindows = existingAll,
            durationMs = durationMs,
            nowMillis = now,
            dayEndMillis = targetDayBounds?.second,
        )
    } else {
        DynamicWindowPlanResult(emptyList(), skippedCovered = 0, mergedShortGaps = 0)
    }
    logBackfillDiag(
        ctx,
        "buildMissingWorklist plan windows=${plan.windows.size} skippedCovered=${plan.skippedCovered} " +
            "mergedShortGaps=${plan.mergedShortGaps} preview=${plan.windows.take(30).joinToString(";") { window -> "${fmt(window.startTime)}-${fmt(window.endTime)}" }}",
    )
    val missing = ArrayList<DynamicRebuildWindow>(plan.windows.size + 16)
    val dayStats = LinkedHashMap<String, Int>()
    val queuedKeys = HashSet<String>()
    val existingRepairScan = try {
        SegmentDatabaseHelper.listSegmentsNeedingSummary(
            ctx,
            limit = Int.MAX_VALUE,
            sinceMillis = scanStartForExisting,
            endMillis = scanEnd + durationMs,
        )
    } catch (e: Exception) {
        logBackfillDiag(
            ctx,
            "buildMissingWorklist existingRepairScan failed type=${e.javaClass.simpleName} message=${e.message ?: e.toString()}",
        )
        emptyList()
    }
    logBackfillDiag(
        ctx,
        "buildMissingWorklist existingRepairScan count=${existingRepairScan.size} " +
            "preview=${existingRepairScan.take(80).joinToString(";") { seg -> segmentDiag(ctx, seg) }}",
    )
    val existingWithoutResults = ArrayList<SegmentDatabaseHelper.Segment>(existingRepairScan.size)
    var queuedExisting = 0
    var skippedExistingFutureOrInvalid = 0
    var skippedExistingDuplicate = 0
    var skippedExistingNowCompliant = 0
    val skippedExistingPreview = ArrayList<String>()
    for (seg in existingRepairScan) {
        if (
            normalizedTargetDayKey.isNotBlank() &&
            dateKeyFromMillis(seg.startTime) != normalizedTargetDayKey
        ) {
            continue
        }
        if (seg.startTime >= seg.endTime || seg.endTime > now) {
            skippedExistingFutureOrInvalid += 1
            if (skippedExistingPreview.size < 40) {
                skippedExistingPreview.add("seg=${seg.id} reason=invalid_or_future ${fmt(seg.startTime)}-${fmt(seg.endTime)}")
            }
            continue
        }
        val repairReason = resultRepairReasonForSegment(ctx, seg.id)
        if (repairReason == "none") {
            skippedExistingNowCompliant += 1
            if (skippedExistingPreview.size < 40) {
                skippedExistingPreview.add("seg=${seg.id} reason=now_compliant ${fmt(seg.startTime)}-${fmt(seg.endTime)}")
            }
            continue
        }
        existingWithoutResults.add(seg)
        val key = "${seg.startTime}|${seg.endTime}"
        if (!queuedKeys.add(key)) {
            skippedExistingDuplicate += 1
            if (skippedExistingPreview.size < 40) {
                skippedExistingPreview.add("seg=${seg.id} reason=duplicate_window ${fmt(seg.startTime)}-${fmt(seg.endTime)}")
            }
            continue
        }
        missing.add(
            DynamicRebuildWindow(
                startTime = seg.startTime,
                endTime = seg.endTime,
                existingSegmentId = seg.id,
            )
        )
        queuedExisting += 1
        val dayKey = dateKeyFromMillis(seg.startTime)
        dayStats[dayKey] = (dayStats[dayKey] ?: 0) + 1
    }
    var queuedPlanned = 0
    var skippedExactDuplicate = 0
    var skippedOverlapRepair = 0
    var skippedOverlapExisting = 0
    var skippedCoveredUsable = 0
    var skippedWindowDuplicate = 0
    val skippedPlanPreview = ArrayList<String>()
    for (window in plan.windows) {
        if (window.endTime > now) {
            if (skippedPlanPreview.size < 60) {
                skippedPlanPreview.add("window=${fmt(window.startTime)}-${fmt(window.endTime)} reason=future")
            }
            continue
        }
        val exactWithoutResult = existingWithoutResults.firstOrNull {
            it.startTime == window.startTime && it.endTime == window.endTime
        }
        if (exactWithoutResult != null) {
            val key = "${exactWithoutResult.startTime}|${exactWithoutResult.endTime}"
            if (queuedKeys.add(key)) {
                missing.add(
                    DynamicRebuildWindow(
                        startTime = exactWithoutResult.startTime,
                        endTime = exactWithoutResult.endTime,
                        existingSegmentId = exactWithoutResult.id,
                    )
                )
                val dayKey = dateKeyFromMillis(exactWithoutResult.startTime)
                dayStats[dayKey] = (dayStats[dayKey] ?: 0) + 1
                queuedExisting += 1
            } else {
                skippedExactDuplicate += 1
                if (skippedPlanPreview.size < 60) {
                    skippedPlanPreview.add("window=${fmt(window.startTime)}-${fmt(window.endTime)} reason=exact_existing_already_queued seg=${exactWithoutResult.id}")
                }
            }
            continue
        }
        if (existingWithoutResults.any {
                it.startTime < window.endTime && it.endTime > window.startTime
            }) {
            skippedOverlapRepair += 1
            if (skippedPlanPreview.size < 60) {
                skippedPlanPreview.add("window=${fmt(window.startTime)}-${fmt(window.endTime)} reason=overlaps_existing_repair")
            }
            continue
        }
        val overlappingExisting = existingAll.firstOrNull {
            it.startTime < window.endTime && it.endTime > window.startTime
        }
        if (overlappingExisting != null) {
            skippedOverlapExisting += 1
            if (skippedPlanPreview.size < 60) {
                skippedPlanPreview.add(
                    "window=${fmt(window.startTime)}-${fmt(window.endTime)} reason=overlaps_existing_root seg=${overlappingExisting.segmentId} compliant=${overlappingExisting.hasCompliantResult}",
                )
            }
            continue
        }
        val covered = try {
            SegmentDatabaseHelper.hasUsableResultCoveringWindow(
                ctx,
                window.startTime,
                window.endTime,
                requireCompliantJson = true,
            )
        } catch (_: Exception) {
            false
        }
        if (covered) {
            skippedCoveredUsable += 1
            if (skippedPlanPreview.size < 60) {
                skippedPlanPreview.add("window=${fmt(window.startTime)}-${fmt(window.endTime)} reason=covered_by_compliant_result")
            }
            continue
        }
        val key = "${window.startTime}|${window.endTime}"
        if (!queuedKeys.add(key)) {
            skippedWindowDuplicate += 1
            if (skippedPlanPreview.size < 60) {
                skippedPlanPreview.add("window=${fmt(window.startTime)}-${fmt(window.endTime)} reason=duplicate_planned_window")
            }
            continue
        }
        missing.add(window)
        queuedPlanned += 1
        val dayKey = dateKeyFromMillis(window.startTime)
        dayStats[dayKey] = (dayStats[dayKey] ?: 0) + 1
    }
    logBackfillDiag(
        ctx,
            "buildMissingWorklist queueSummary missing=${missing.size} queuedExisting=$queuedExisting queuedPlanned=$queuedPlanned " +
            "skippedExistingInvalidOrFuture=$skippedExistingFutureOrInvalid skippedExistingDuplicate=$skippedExistingDuplicate " +
            "skippedExistingNowCompliant=$skippedExistingNowCompliant " +
            "skippedExactDuplicate=$skippedExactDuplicate skippedOverlapRepair=$skippedOverlapRepair " +
            "skippedOverlapExisting=$skippedOverlapExisting " +
            "skippedCoveredUsable=$skippedCoveredUsable skippedWindowDuplicate=$skippedWindowDuplicate " +
            "skippedExistingPreview=${skippedExistingPreview.joinToString(";")} skippedPlanPreview=${skippedPlanPreview.joinToString(";")}",
    )
    logBackfillDiag(
        ctx,
        "buildMissingWorklist missingPreview=${missing.take(120).joinToString(";") { window -> "${fmt(window.startTime)}-${fmt(window.endTime)} existingSegmentId=${window.existingSegmentId}" }}",
    )
    if (missing.isNotEmpty()) {
        val preview = dayStats.entries.take(12).joinToString(", ") { "${it.key}:${it.value}" }
        try {
            FileLogger.i(
                TAG,
                "backfillMissing: shots=${shots.size} planned=${plan.windows.size} missing=${missing.size} skippedCovered=${plan.skippedCovered} mergedShortGaps=${plan.mergedShortGaps} days=${dayStats.size} preview=$preview",
            )
        } catch (_: Exception) {}
    } else {
        try { FileLogger.i(TAG, "backfillMissing: shots=${shots.size} planned=${plan.windows.size} missing=0 skippedCovered=${plan.skippedCovered} mergedShortGaps=${plan.mergedShortGaps}") } catch (_: Exception) {}
    }
    return missing
}

internal fun SegmentSummaryManager.filterDynamicRebuildWindowsForDayInternal(
    windows: List<DynamicRebuildWindow>,
    targetDayKey: String,
): List<DynamicRebuildWindow> {
    val normalizedTarget = targetDayKey.trim()
    if (normalizedTarget.isBlank()) return windows
    return windows.filter { dateKeyFromMillis(it.startTime) == normalizedTarget }
}
