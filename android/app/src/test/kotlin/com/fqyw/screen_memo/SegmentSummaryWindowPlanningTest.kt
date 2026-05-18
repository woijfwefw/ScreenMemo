package com.fqyw.screen_memo

import com.fqyw.screen_memo.segment.SegmentSummaryManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SegmentSummaryWindowPlanningTest {
    @Test
    fun planNonOverlappingWindows_keepsPlainWindows() {
        val result = SegmentSummaryManager.planNonOverlappingWindows(
            shotTimes = listOf(10_000L, 70_000L, 130_000L, 190_000L),
            existingWindows = emptyList(),
            durationMs = 120_000L,
            nowMillis = 400_000L,
        )

        assertEquals(listOf(10_000L, 130_000L), result.windows.map { it.startTime })
        assertEquals(listOf(130_000L, 250_000L), result.windows.map { it.endTime })
        assertEquals(0, result.skippedCovered)
        assertEquals(0, result.mergedShortGaps)
    }

    @Test
    fun planNonOverlappingWindows_skipsFullyCoveredWindow() {
        val result = SegmentSummaryManager.planNonOverlappingWindows(
            shotTimes = listOf(10_000L, 60_000L, 120_000L, 240_000L),
            existingWindows = listOf(
                SegmentSummaryManager.ExistingDynamicWindow(0L, 180_000L, 1L),
            ),
            durationMs = 120_000L,
            nowMillis = 500_000L,
        )

        assertEquals(listOf(240_000L), result.windows.map { it.startTime })
        assertEquals(listOf(360_000L), result.windows.map { it.endTime })
        assertTrue(result.skippedCovered > 0)
    }

    @Test
    fun planNonOverlappingWindows_advancesPastPartialOverlap() {
        val result = SegmentSummaryManager.planNonOverlappingWindows(
            shotTimes = listOf(10_000L, 60_000L, 180_000L, 240_000L, 360_000L),
            existingWindows = listOf(
                SegmentSummaryManager.ExistingDynamicWindow(90_000L, 240_000L, 1L),
            ),
            durationMs = 120_000L,
            nowMillis = 400_000L,
        )

        assertEquals(listOf(240_000L), result.windows.map { it.startTime })
        assertEquals(listOf(360_000L), result.windows.map { it.endTime })
        assertEquals(1, result.mergedShortGaps)
    }

    @Test
    fun planNonOverlappingWindows_doesNotCreateShortGapBeforeNextSegment() {
        val result = SegmentSummaryManager.planNonOverlappingWindows(
            shotTimes = listOf(10_000L, 30_000L, 60_000L, 90_000L, 200_000L),
            existingWindows = listOf(
                SegmentSummaryManager.ExistingDynamicWindow(90_000L, 200_000L, 1L),
            ),
            durationMs = 120_000L,
            nowMillis = 500_000L,
        )

        assertEquals(listOf(200_000L), result.windows.map { it.startTime })
        assertEquals(listOf(320_000L), result.windows.map { it.endTime })
        assertEquals(1, result.mergedShortGaps)
    }

    @Test
    fun planNonOverlappingWindows_respectsDayEndForCrossDayRepair() {
        val result = SegmentSummaryManager.planNonOverlappingWindows(
            shotTimes = listOf(80_000L, 120_000L, 260_000L),
            existingWindows = listOf(
                SegmentSummaryManager.ExistingDynamicWindow(0L, 120_000L, 1L),
            ),
            durationMs = 120_000L,
            nowMillis = 500_000L,
            dayEndMillis = 200_000L,
        )

        assertEquals(listOf(120_000L), result.windows.map { it.startTime })
        assertEquals(listOf(240_000L), result.windows.map { it.endTime })
    }

    @Test
    fun dynamicRebuildWindow_carriesExistingSegmentIdForNoSummaryReuse() {
        val window = SegmentSummaryManager.DynamicRebuildWindow(
            startTime = 10_000L,
            endTime = 130_000L,
            existingSegmentId = 42L,
        )

        assertEquals(42L, window.existingSegmentId)
    }

    @Test
    fun filterDynamicRebuildWindowsForDay_keepsOnlyTargetDay() {
        val windows = listOf(
            SegmentSummaryManager.DynamicRebuildWindow(
                startTime = 1_713_270_600_000L, // 2024-04-16 local/UTC daytime
                endTime = 1_713_274_200_000L,
            ),
            SegmentSummaryManager.DynamicRebuildWindow(
                startTime = 1_713_357_000_000L, // 2024-04-17 local/UTC daytime
                endTime = 1_713_360_600_000L,
            ),
        )

        val result = SegmentSummaryManager.filterDynamicRebuildWindowsForDay(
            windows,
            "2024-04-17",
        )

        assertEquals(1, result.size)
        assertEquals(windows[1].startTime, result.first().startTime)
    }

    @Test
    fun filterDynamicRebuildWindowsForDay_keepsAllWhenTargetBlank() {
        val windows = listOf(
            SegmentSummaryManager.DynamicRebuildWindow(10_000L, 130_000L),
            SegmentSummaryManager.DynamicRebuildWindow(140_000L, 260_000L),
        )

        val result = SegmentSummaryManager.filterDynamicRebuildWindowsForDay(
            windows,
            "",
        )

        assertEquals(windows, result)
    }

    @Test
    fun planNonOverlappingWindows_skipsShortGapThenContinuesAfterExistingSegment() {
        val result = SegmentSummaryManager.planNonOverlappingWindows(
            shotTimes = listOf(100_000L, 160_000L, 200_000L, 320_000L),
            existingWindows = listOf(
                SegmentSummaryManager.ExistingDynamicWindow(0L, 100_000L, 1L),
                SegmentSummaryManager.ExistingDynamicWindow(180_000L, 320_000L, 2L),
            ),
            durationMs = 120_000L,
            nowMillis = 500_000L,
        )

        assertEquals(listOf(320_000L), result.windows.map { it.startTime })
        assertEquals(listOf(440_000L), result.windows.map { it.endTime })
        assertEquals(1, result.mergedShortGaps)
    }
}
