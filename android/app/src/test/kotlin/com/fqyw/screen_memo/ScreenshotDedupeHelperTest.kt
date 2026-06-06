package com.fqyw.screen_memo

import com.fqyw.screen_memo.capture.ScreenshotDedupeHelper
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenshotDedupeHelperTest {
    private val width = 128
    private val height = 128

    @Test
    fun shouldSkip_identicalImageInExactMode() {
        val base = baseFrame()
        val previous = features(base).toSignature()
        val current = features(base.copyOf())

        val result = ScreenshotDedupeHelper.shouldSkip(
            previous,
            current,
            ScreenshotDedupeHelper.Mode.EXACT,
        )

        assertTrue(result.duplicate)
    }

    @Test
    fun shouldSkip_horizontalStripeJitterInBalancedMode() {
        val base = baseFrame()
        val currentPixels = base.copyOf()
        drawHorizontalLine(currentPixels, y = 63, color = 0xffe2e2e2.toInt())
        val previous = features(base).toSignature()
        val current = features(currentPixels)

        val result = ScreenshotDedupeHelper.shouldSkip(
            previous,
            current,
            ScreenshotDedupeHelper.Mode.BALANCED,
        )

        assertTrue(result.duplicate)
    }

    @Test
    fun shouldSkip_verticalStripeJitterInBalancedMode() {
        val base = baseFrame()
        val currentPixels = base.copyOf()
        drawVerticalLine(currentPixels, x = 63, color = 0xffe2e2e2.toInt())
        val previous = features(base).toSignature()
        val current = features(currentPixels)

        val result = ScreenshotDedupeHelper.shouldSkip(
            previous,
            current,
            ScreenshotDedupeHelper.Mode.BALANCED,
        )

        assertTrue(result.duplicate)
    }

    @Test
    fun shouldSkip_smallPopupIsNotDuplicate() {
        val base = baseFrame()
        val currentPixels = base.copyOf()
        drawRect(currentPixels, left = 42, top = 42, right = 86, bottom = 82, color = 0xff202020.toInt())
        val previous = features(base).toSignature()
        val current = features(currentPixels)

        val result = ScreenshotDedupeHelper.shouldSkip(
            previous,
            current,
            ScreenshotDedupeHelper.Mode.BALANCED,
        )

        assertFalse(result.duplicate)
    }

    @Test
    fun shouldSkip_obviousScrollIsNotDuplicate() {
        val base = baseFrameWithTextBands()
        val currentPixels = shiftUp(base, distance = 16)
        val previous = features(base).toSignature()
        val current = features(currentPixels)

        val result = ScreenshotDedupeHelper.shouldSkip(
            previous,
            current,
            ScreenshotDedupeHelper.Mode.BALANCED,
        )

        assertFalse(result.duplicate)
    }

    @Test
    fun shouldSkip_textLikeContentChangeIsNotDuplicate() {
        val base = baseFrameWithTextBands()
        val currentPixels = base.copyOf()
        drawRect(currentPixels, left = 24, top = 56, right = 104, bottom = 64, color = 0xff202020.toInt())
        drawRect(currentPixels, left = 24, top = 68, right = 88, bottom = 76, color = 0xff202020.toInt())
        val previous = features(base).toSignature()
        val current = features(currentPixels)

        val result = ScreenshotDedupeHelper.shouldSkip(
            previous,
            current,
            ScreenshotDedupeHelper.Mode.BALANCED,
        )

        assertFalse(result.duplicate)
    }

    @Test
    fun shouldSkip_exactModeRejectsNearMatch() {
        val base = baseFrame()
        val currentPixels = base.copyOf()
        drawHorizontalLine(currentPixels, y = 63, color = 0xffe2e2e2.toInt())
        val previous = features(base).toSignature()
        val current = features(currentPixels)

        val result = ScreenshotDedupeHelper.shouldSkip(
            previous,
            current,
            ScreenshotDedupeHelper.Mode.EXACT,
        )

        assertFalse(result.duplicate)
    }

    @Test
    fun shouldSkip_invalidLegacySignatureFallsBackToNonDuplicate() {
        val current = features(baseFrame())

        val result = ScreenshotDedupeHelper.shouldSkip(
            "legacy-bad-signature",
            current,
            ScreenshotDedupeHelper.Mode.BALANCED,
        )

        assertFalse(result.duplicate)
    }

    @Test
    fun sampleSizeForMode_exactKeepsFullResolution() {
        val size = ScreenshotDedupeHelper.sampleSizeForMode(
            width = 1440,
            height = 3120,
            mode = ScreenshotDedupeHelper.Mode.EXACT,
        )

        assertTrue(size.width == 1440)
        assertTrue(size.height == 3120)
    }

    @Test
    fun sampleSizeForMode_balancedDownsamplesLargeFrames() {
        val size = ScreenshotDedupeHelper.sampleSizeForMode(
            width = 1440,
            height = 3120,
            mode = ScreenshotDedupeHelper.Mode.BALANCED,
        )

        assertTrue(size.width == 44)
        assertTrue(size.height == 96)
    }

    private fun baseFrame(): IntArray {
        return IntArray(width * height) { 0xffeeeeee.toInt() }
    }

    private fun baseFrameWithTextBands(): IntArray {
        val pixels = baseFrame()
        for (y in 18 until 110 step 18) {
            drawRect(pixels, left = 18, top = y, right = 110, bottom = y + 6, color = 0xff606060.toInt())
        }
        return pixels
    }

    private fun features(pixels: IntArray): ScreenshotDedupeHelper.FrameFeatures {
        return ScreenshotDedupeHelper.buildFeatures(width, height, pixels)
    }

    private fun drawHorizontalLine(pixels: IntArray, y: Int, color: Int) {
        for (x in 0 until width) {
            pixels[y * width + x] = color
        }
    }

    private fun drawVerticalLine(pixels: IntArray, x: Int, color: Int) {
        for (y in 0 until height) {
            pixels[y * width + x] = color
        }
    }

    private fun drawRect(
        pixels: IntArray,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        color: Int,
    ) {
        for (y in top.coerceAtLeast(0) until bottom.coerceAtMost(height)) {
            val rowOffset = y * width
            for (x in left.coerceAtLeast(0) until right.coerceAtMost(width)) {
                pixels[rowOffset + x] = color
            }
        }
    }

    private fun shiftUp(source: IntArray, distance: Int): IntArray {
        val out = baseFrame()
        for (y in 0 until height - distance) {
            val srcOffset = (y + distance) * width
            val dstOffset = y * width
            for (x in 0 until width) {
                out[dstOffset + x] = source[srcOffset + x]
            }
        }
        return out
    }
}
