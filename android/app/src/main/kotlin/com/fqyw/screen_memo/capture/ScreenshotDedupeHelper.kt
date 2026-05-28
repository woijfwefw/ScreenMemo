package com.fqyw.screen_memo.capture

import java.security.MessageDigest
import java.util.Locale
import kotlin.math.abs

/**
 * 截图近似去重的纯算法工具。
 *
 * 输入使用已经裁剪系统栏后的灰度缩略图，避免算法依赖 Android Bitmap，便于 JVM 单测覆盖。
 */
object ScreenshotDedupeHelper {
    private const val SIGNATURE_VERSION = "v2"
    private const val THUMB_SIZE = 32
    private const val DHASH_WIDTH = 9
    private const val DHASH_HEIGHT = 8
    private const val BLOCK_GRID = 8
    private const val THUMB_CELL_DIFF_THRESHOLD = 64
    private const val THUMB_BLOCK_DIFF_THRESHOLD = 32
    private const val THUMB_ROW_COL_DIFF_THRESHOLD = 64

    enum class Mode(
        val rawValue: String,
        val maxHashDistance: Int,
        val maxChangedPixelRatio: Double,
        val maxChangedBlocks: Int
    ) {
        EXACT("exact", 0, 0.0, 0),
        CONSERVATIVE("conservative", 4, 0.008, 2),
        BALANCED("balanced", 8, 0.015, 4),
        AGGRESSIVE("aggressive", 14, 0.03, 8);

        companion object {
            fun fromRaw(raw: String?): Mode {
                return when (raw?.trim()?.lowercase(Locale.ROOT)) {
                    EXACT.rawValue -> EXACT
                    CONSERVATIVE.rawValue -> CONSERVATIVE
                    AGGRESSIVE.rawValue -> AGGRESSIVE
                    else -> BALANCED
                }
            }
        }
    }

    data class FrameFeatures(
        val width: Int,
        val height: Int,
        val exactHash: String,
        val dHash: Long,
        val thumb: ByteArray
    ) {
        fun toSignature(): String {
            return listOf(
                SIGNATURE_VERSION,
                "${width}x${height}",
                exactHash,
                dHash.toULong().toString(16).padStart(16, '0'),
                thumb.joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
            ).joinToString("|")
        }
    }

    data class CompareResult(
        val duplicate: Boolean,
        val reason: String,
        val hashDistance: Int = -1,
        val changedPixelRatio: Double = 1.0,
        val changedBlocks: Int = BLOCK_GRID * BLOCK_GRID,
        val changedRows: Int = THUMB_SIZE,
        val changedCols: Int = THUMB_SIZE
    )

    fun buildFeatures(
        width: Int,
        height: Int,
        argbPixels: IntArray
    ): FrameFeatures {
        require(width > 0) { "width must be positive" }
        require(height > 0) { "height must be positive" }
        require(argbPixels.size >= width * height) { "not enough pixels" }

        val exactHash = computeExactHash(width, height, argbPixels)
        val dHash = computeDHash(width, height, argbPixels)
        val thumb = buildThumb(width, height, argbPixels)
        return FrameFeatures(width, height, exactHash, dHash, thumb)
    }

    fun shouldSkip(
        previousSignature: String?,
        current: FrameFeatures,
        mode: Mode
    ): CompareResult {
        val previous = parseSignature(previousSignature)
            ?: return CompareResult(false, "no_previous_signature")

        if (previous.width != current.width || previous.height != current.height) {
            return CompareResult(false, "size_changed")
        }

        if (previous.exactHash == current.exactHash) {
            return CompareResult(true, "exact_match", 0, 0.0, 0, 0, 0)
        }

        if (mode == Mode.EXACT) {
            return CompareResult(false, "exact_mode_changed")
        }

        val hashDistance = hammingDistance(previous.dHash, current.dHash)
        if (hashDistance > mode.maxHashDistance) {
            return CompareResult(false, "hash_distance", hashDistance)
        }

        val thumbDiff = compareThumbs(previous.thumb, current.thumb)
        if (thumbDiff.changedPixelRatio > mode.maxChangedPixelRatio) {
            return CompareResult(
                false,
                "changed_pixel_ratio",
                hashDistance,
                thumbDiff.changedPixelRatio,
                thumbDiff.changedBlocks,
                thumbDiff.changedRows,
                thumbDiff.changedCols
            )
        }
        if (thumbDiff.changedBlocks > mode.maxChangedBlocks) {
            return CompareResult(
                false,
                "changed_blocks",
                hashDistance,
                thumbDiff.changedPixelRatio,
                thumbDiff.changedBlocks,
                thumbDiff.changedRows,
                thumbDiff.changedCols
            )
        }
        val rowColThreshold = when (mode) {
            Mode.EXACT -> 0
            Mode.CONSERVATIVE -> 2
            Mode.BALANCED -> 4
            Mode.AGGRESSIVE -> 8
        }
        if (thumbDiff.changedRows > rowColThreshold || thumbDiff.changedCols > rowColThreshold) {
            return CompareResult(
                false,
                "changed_rows_cols",
                hashDistance,
                thumbDiff.changedPixelRatio,
                thumbDiff.changedBlocks,
                thumbDiff.changedRows,
                thumbDiff.changedCols
            )
        }

        return CompareResult(
            true,
            "perceptual_match",
            hashDistance,
            thumbDiff.changedPixelRatio,
            thumbDiff.changedBlocks,
            thumbDiff.changedRows,
            thumbDiff.changedCols
        )
    }

    fun parseSignature(raw: String?): FrameFeatures? {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return null

        if (!text.startsWith("$SIGNATURE_VERSION|")) {
            return parseLegacyExactSignature(text)
        }

        val parts = text.split('|')
        if (parts.size != 5) return null
        val size = parts[1].split('x')
        if (size.size != 2) return null
        val width = size[0].toIntOrNull() ?: return null
        val height = size[1].toIntOrNull() ?: return null
        val exactHash = parts[2].takeIf { it.isNotBlank() } ?: return null
        val dHash = parts[3].toULongOrNull(16)?.toLong() ?: return null
        val thumb = hexToBytes(parts[4]) ?: return null
        if (thumb.size != THUMB_SIZE * THUMB_SIZE) return null
        return FrameFeatures(width, height, exactHash, dHash, thumb)
    }

    private fun parseLegacyExactSignature(raw: String): FrameFeatures? {
        val sep = raw.indexOf(':')
        if (sep <= 0 || sep >= raw.length - 1) return null
        val size = raw.substring(0, sep).split('x')
        if (size.size != 2) return null
        val width = size[0].toIntOrNull() ?: return null
        val height = size[1].toIntOrNull() ?: return null
        val exactHash = raw.substring(sep + 1).takeIf { it.isNotBlank() } ?: return null
        return FrameFeatures(width, height, exactHash, 0L, ByteArray(THUMB_SIZE * THUMB_SIZE))
    }

    private data class ThumbDiff(
        val changedPixelRatio: Double,
        val changedBlocks: Int,
        val changedRows: Int,
        val changedCols: Int
    )

    private fun compareThumbs(previous: ByteArray, current: ByteArray): ThumbDiff {
        if (previous.size != THUMB_SIZE * THUMB_SIZE || current.size != THUMB_SIZE * THUMB_SIZE) {
            return ThumbDiff(1.0, BLOCK_GRID * BLOCK_GRID, THUMB_SIZE, THUMB_SIZE)
        }

        var changedCells = 0
        var changedBlocks = 0
        val rowDiffSums = LongArray(THUMB_SIZE)
        val colDiffSums = LongArray(THUMB_SIZE)
        val blockSize = THUMB_SIZE / BLOCK_GRID
        for (by in 0 until BLOCK_GRID) {
            for (bx in 0 until BLOCK_GRID) {
                var blockDeltaSum = 0L
                for (y in 0 until blockSize) {
                    for (x in 0 until blockSize) {
                        val px = bx * blockSize + x
                        val py = by * blockSize + y
                        val index = py * THUMB_SIZE + px
                        val diff = abs((previous[index].toInt() and 0xff) - (current[index].toInt() and 0xff))
                        blockDeltaSum += diff
                        rowDiffSums[py] += diff
                        colDiffSums[px] += diff
                        if (diff >= THUMB_CELL_DIFF_THRESHOLD) {
                            changedCells++
                        }
                    }
                }
                val averageBlockDelta = blockDeltaSum / (blockSize * blockSize)
                if (averageBlockDelta >= THUMB_BLOCK_DIFF_THRESHOLD) {
                    changedBlocks++
                }
            }
        }

        val changedRows = rowDiffSums.count {
            it / THUMB_SIZE >= THUMB_ROW_COL_DIFF_THRESHOLD
        }
        val changedCols = colDiffSums.count {
            it / THUMB_SIZE >= THUMB_ROW_COL_DIFF_THRESHOLD
        }

        return ThumbDiff(
            changedPixelRatio = changedCells.toDouble() / (THUMB_SIZE * THUMB_SIZE).toDouble(),
            changedBlocks = changedBlocks,
            changedRows = changedRows,
            changedCols = changedCols
        )
    }

    private fun computeExactHash(width: Int, height: Int, argbPixels: IntArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        updateInt(digest, width)
        updateInt(digest, height)
        for (i in 0 until width * height) {
            updateInt(digest, argbPixels[i])
        }
        return digest.digest().joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun computeDHash(width: Int, height: Int, argbPixels: IntArray): Long {
        var hash = 0L
        for (y in 0 until DHASH_HEIGHT) {
            for (x in 0 until DHASH_WIDTH - 1) {
                val left = sampleGray(width, height, argbPixels, x, y, DHASH_WIDTH, DHASH_HEIGHT)
                val right = sampleGray(width, height, argbPixels, x + 1, y, DHASH_WIDTH, DHASH_HEIGHT)
                hash = (hash shl 1) or if (left > right) 1L else 0L
            }
        }
        return hash
    }

    private fun buildThumb(width: Int, height: Int, argbPixels: IntArray): ByteArray {
        val out = ByteArray(THUMB_SIZE * THUMB_SIZE)
        for (y in 0 until THUMB_SIZE) {
            val y0 = y * height / THUMB_SIZE
            val y1 = ((y + 1) * height / THUMB_SIZE).coerceAtLeast(y0 + 1)
            for (x in 0 until THUMB_SIZE) {
                val x0 = x * width / THUMB_SIZE
                val x1 = ((x + 1) * width / THUMB_SIZE).coerceAtLeast(x0 + 1)
                var sum = 0L
                var count = 0
                for (srcY in y0 until y1) {
                    val rowOffset = srcY * width
                    for (srcX in x0 until x1) {
                        sum += gray(argbPixels[rowOffset + srcX]).toLong()
                        count++
                    }
                }
                val avg = if (count > 0) (sum / count).toInt() else 0
                out[y * THUMB_SIZE + x] = avg.coerceIn(0, 255).toByte()
            }
        }
        return out
    }

    private fun sampleGray(
        width: Int,
        height: Int,
        argbPixels: IntArray,
        sampleX: Int,
        sampleY: Int,
        sampleWidth: Int,
        sampleHeight: Int
    ): Int {
        val srcX = ((sampleX + 0.5) * width / sampleWidth).toInt().coerceIn(0, width - 1)
        val srcY = ((sampleY + 0.5) * height / sampleHeight).toInt().coerceIn(0, height - 1)
        return gray(argbPixels[srcY * width + srcX])
    }

    private fun gray(argb: Int): Int {
        val r = (argb shr 16) and 0xff
        val g = (argb shr 8) and 0xff
        val b = argb and 0xff
        return ((r * 299) + (g * 587) + (b * 114)) / 1000
    }

    private fun updateInt(digest: MessageDigest, value: Int) {
        digest.update((value ushr 24).toByte())
        digest.update((value ushr 16).toByte())
        digest.update((value ushr 8).toByte())
        digest.update(value.toByte())
    }

    private fun hammingDistance(a: Long, b: Long): Int {
        return java.lang.Long.bitCount(a xor b)
    }

    private fun hexToBytes(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        val out = ByteArray(hex.length / 2)
        for (i in out.indices) {
            val hi = hexDigit(hex[i * 2]) ?: return null
            val lo = hexDigit(hex[i * 2 + 1]) ?: return null
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }

    private fun hexDigit(ch: Char): Int? {
        return when (ch) {
            in '0'..'9' -> ch - '0'
            in 'a'..'f' -> ch - 'a' + 10
            in 'A'..'F' -> ch - 'A' + 10
            else -> null
        }
    }
}
