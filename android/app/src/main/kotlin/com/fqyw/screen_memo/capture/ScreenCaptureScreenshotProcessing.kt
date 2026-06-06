package com.fqyw.screen_memo.capture

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.os.Build
import android.os.SystemClock
import android.system.Os
import com.fqyw.screen_memo.database.ScreenshotDatabaseHelper
import com.fqyw.screen_memo.logging.FileLogger
import com.fqyw.screen_memo.settings.PerAppSettingsBridge
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.io.File
import java.io.FileOutputStream

private const val TAG = "ScreenCaptureService"

    internal fun ScreenCaptureAccessibilityService.runOcrAsyncAndPersist(
        srcBitmap: Bitmap,
        absolutePath: String,
        recycleSourceWhenDone: Boolean = false,
        traceId: Long = nextCaptureTraceId()
    ) {
        try {
            val setupStartMs = SystemClock.elapsedRealtime()
            val recognizer = ensureTextRecognizer()
            val setupMs = SystemClock.elapsedRealtime() - setupStartMs
            ocrExecutor.execute {
                val ocrStartMs = SystemClock.elapsedRealtime()
                var preprocessMs = 0L
                var recognizeMs = 0L
                var dbMs = 0L
                var portrait = true
                try {
                    portrait = try { srcBitmap.height >= srcBitmap.width } catch (_: Exception) { true }
                    val preprocessStartMs = SystemClock.elapsedRealtime()
                    val base = if (portrait) {
                        val topCropped = cropTopStatusBarPortrait(srcBitmap)
                        val bothCropped = cropBottomNavBarPortrait(topCropped)
                        preprocessForOcrPortrait(bothCropped)
                    } else srcBitmap
                    preprocessMs = SystemClock.elapsedRealtime() - preprocessStartMs
                    val recognizeStartMs = SystemClock.elapsedRealtime()
                    val text = if (portrait) {
                        recognizePortraitBySlices(recognizer, base)
                    } else {
                        // 横屏暂用整图识别
                        val img = InputImage.fromBitmap(base, 0)
                        try { Tasks.await(recognizer.process(img)).text ?: "" } catch (e: Exception) { "" }
                    }
                    recognizeMs = SystemClock.elapsedRealtime() - recognizeStartMs
                    val finalText = text.trim().ifEmpty { null }
                    val dbStartMs = SystemClock.elapsedRealtime()
                    ScreenshotDatabaseHelper.updateOcrTextByFilePath(
                        this,
                        absolutePath,
                        finalText
                    )
                    dbMs = SystemClock.elapsedRealtime() - dbStartMs
                    perf(
                        "trace=$traceId stage=ocr_complete result=ok portrait=$portrait " +
                            "setupMs=$setupMs preprocessMs=$preprocessMs recognizeMs=$recognizeMs dbMs=$dbMs " +
                            "ocrTotalMs=${SystemClock.elapsedRealtime() - ocrStartMs} textLength=${finalText?.length ?: 0} " +
                            "path=$absolutePath"
                    )
                    FileLogger.i(TAG, "OCR完成(切片=${portrait}), 长度=${finalText?.length ?: 0}")
                } catch (e: Exception) {
                    perf(
                        "trace=$traceId stage=ocr_complete result=exception portrait=$portrait " +
                            "setupMs=$setupMs preprocessMs=$preprocessMs recognizeMs=$recognizeMs dbMs=$dbMs " +
                            "ocrTotalMs=${SystemClock.elapsedRealtime() - ocrStartMs} message=${e.message ?: "-"} path=$absolutePath"
                    )
                    FileLogger.w(TAG, "OCR线程异常: ${e.message}")
                } finally {
                    if (recycleSourceWhenDone) {
                        try { srcBitmap.recycle() } catch (_: Exception) {}
                    }
                }
            }
        } catch (e: Exception) {
            perf(
                "trace=$traceId stage=ocr_launch result=exception " +
                    "message=${e.message ?: "-"} path=$absolutePath"
            )
            FileLogger.w(TAG, "启动OCR异常: ${e.message}")
            if (recycleSourceWhenDone) {
                try { srcBitmap.recycle() } catch (_: Exception) {}
            }
        }
    }

    private fun ScreenCaptureAccessibilityService.ensureTextRecognizer(): com.google.mlkit.vision.text.TextRecognizer {
        val existing = sharedTextRecognizer
        if (existing != null) return existing
        val created = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
        sharedTextRecognizer = created
        return created
    }

    /**
     * 裁剪竖屏截图顶部状态栏区域，避免无关内容参与识别。
     */
    private fun ScreenCaptureAccessibilityService.cropTopStatusBarPortrait(src: Bitmap): Bitmap {
        return try {
            val w = src.width
            val h = src.height
            val status = getStatusBarHeight().coerceAtLeast(0)
            val cropTop = status.coerceAtMost(h / 6)
            if (cropTop <= 0 || cropTop >= h - 16) return src
            Bitmap.createBitmap(src, 0, cropTop, w, h - cropTop)
        } catch (_: Exception) { src }
    }

    /**
     * 竖屏：对比度增强 + 轻锐化（不旋转、不改分辨率）。
     */
    private fun ScreenCaptureAccessibilityService.preprocessForOcrPortrait(src: Bitmap): Bitmap {
        return try {
            val w = src.width
            val h = src.height
            val safe = if (src.config != Bitmap.Config.ARGB_8888) src.copy(Bitmap.Config.ARGB_8888, true) else src.copy(Bitmap.Config.ARGB_8888, true)
            val pixels = IntArray(w * h)
            safe.getPixels(pixels, 0, w, 0, 0, w, h)
            // 简单对比度增强（可配置：flutter.ocr_contrast_1e2，默认118 => 1.18）
            val sp = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val cVal = spGetIntCompat(sp, "flutter.ocr_contrast_1e2", 118).coerceIn(100, 140)
            val contrast = cVal / 100f
            val brightness = 0f
            for (i in pixels.indices) {
                val c = pixels[i]
                val a = c ushr 24 and 0xFF
                var r = c ushr 16 and 0xFF
                var g = c ushr 8 and 0xFF
                var b = c and 0xFF
                r = clamp255(((r - 128) * contrast + 128 + brightness).toInt())
                g = clamp255(((g - 128) * contrast + 128 + brightness).toInt())
                b = clamp255(((b - 128) * contrast + 128 + brightness).toInt())
                pixels[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
            }
            safe.setPixels(pixels, 0, w, 0, 0, w, h)
            safe
        } catch (_: Exception) { src }
    }

    private fun clamp255(v: Int): Int = if (v < 0) 0 else if (v > 255) 255 else v

    /**
     * 竖屏切片 + 小字放大：纵向步进切片，重叠15%，宽度不足则放大至1080。
     */
    private fun ScreenCaptureAccessibilityService.recognizePortraitBySlices(recognizer: com.google.mlkit.vision.text.TextRecognizer, bmp: Bitmap): String {
        val w = bmp.width
        val h = bmp.height
        val sp = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val sliceTarget = spGetIntCompat(sp, "flutter.ocr_slice_height", 1900).coerceIn(900, 2600)
        val overlapPct = spGetIntCompat(sp, "flutter.ocr_slice_overlap_percent", 22).coerceIn(8, 35)
        val overlapRatio = overlapPct / 100f
        val step = (sliceTarget * (1 - overlapRatio)).toInt().coerceAtLeast(500)
        val slices = mutableListOf<Bitmap>()
        var y = 0
        while (y < h) {
            val sh = if (y + sliceTarget <= h) sliceTarget else (h - y)
            if (sh <= 0) break
            try {
                val sub = Bitmap.createBitmap(bmp, 0, y, w, sh)
                val scaled = upscaleIfNeeded(sub)
                if (scaled !== sub) sub.recycle()
                slices.add(scaled)
            } catch (_: Exception) {}
            y += step
        }
        if (slices.isEmpty()) {
            val img = InputImage.fromBitmap(bmp, 0)
            return try { Tasks.await(recognizer.process(img)).text ?: "" } catch (e: Exception) { "" }
        }
        val seen = LinkedHashSet<String>()
        for (s in slices) {
            try {
                val text = Tasks.await(recognizer.process(InputImage.fromBitmap(s, 0)))
                for (block in text.textBlocks) {
                    for (line in block.lines) {
                        val t = line.text?.trim() ?: ""
                        if (t.isNotEmpty() && !seen.contains(t)) {
                            seen.add(t)
                        }
                    }
                }
            } catch (_: Exception) {
            } finally {
                try { s.recycle() } catch (_: Exception) {}
            }
        }
        if (seen.isEmpty()) {
            // 回退：整图一次
            val img = InputImage.fromBitmap(bmp, 0)
            return try { Tasks.await(recognizer.process(img)).text ?: "" } catch (e: Exception) { "" }
        }
        val sb = StringBuilder()
        for (l in seen) {
            if (sb.isNotEmpty()) sb.append('\n')
            sb.append(l)
        }
        return sb.toString()
    }

    private fun ScreenCaptureAccessibilityService.upscaleIfNeeded(bm: Bitmap): Bitmap {
        return try {
            val sp = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val minWidth = spGetIntCompat(sp, "flutter.ocr_upscale_min_width", 1440).coerceIn(900, 2000)
            if (bm.width >= minWidth) bm else {
                val scale = minWidth.toFloat() / bm.width.toFloat()
                val tw = (bm.width * scale).toInt()
                val th = (bm.height * scale).toInt()
                Bitmap.createScaledBitmap(bm, tw, th, true)
            }
        } catch (_: Exception) { bm }
    }

    /**
     * 裁剪竖屏截图底部导航栏区域，减少无关误检。
     */
    private fun ScreenCaptureAccessibilityService.cropBottomNavBarPortrait(src: Bitmap): Bitmap {
        return try {
            val w = src.width
            val h = src.height
            val nav = getNavigationBarHeight().coerceAtLeast(0)
            val cropBottom = nav.coerceAtMost(h / 6)
            if (cropBottom <= 0 || cropBottom >= h - 16) return src
            Bitmap.createBitmap(src, 0, 0, w, h - cropBottom)
        } catch (_: Exception) { src }
    }

    /**
     * 根据用户设置进行编码（格式/质量/目标大小/灰度），不改变分辨率。
     * FlutterSharedPreferences 键：
     *  - flutter.image_format: jpeg | png | webp_lossy | webp_lossless (默认 webp_lossy)
     *  - flutter.image_quality: Int 1..100（默认 90，仅对 lossy 生效）
     *  - flutter.use_target_size: Bool（默认 false，仅对 lossy 生效）
     *  - flutter.target_size_kb: Int（默认 50，仅对 lossy 生效）
     *  - flutter.grayscale: Bool（默认 false）
     */
    internal data class EncodedScreenshot(
        val bytes: ByteArray?,
        val ext: String,
        val deferredTarget: DeferredTargetCompressionSpec? = null
    )

    internal data class DeferredTargetCompressionSpec(
        val formatName: String,
        val compressFormat: Bitmap.CompressFormat,
        val targetBytes: Int,
        val fallbackQuality: Int,
        val targetKb: Int
    )

    // 返回编码结果；目标大小模式会先快速编码，精确压缩延后到独立队列。
    internal fun ScreenCaptureAccessibilityService.encodeToBytesAccordingToSettings(
        src: Bitmap,
        packageName: String?,
        traceId: Long = nextCaptureTraceId()
    ): EncodedScreenshot {
            val totalStartMs = SystemClock.elapsedRealtime()
            var settingsReadMs = 0L
            var perAppReadMs = 0L
            val sp = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val settingsStartMs = SystemClock.elapsedRealtime()
            var format = (sp.getString("flutter.image_format", null)
            ?: (sp.all["flutter.image_format"] as? String)
            ?: "webp_lossy")
            var quality = spGetIntCompat(sp, "flutter.image_quality", 90).coerceIn(1, 100)
            var useTarget = spGetBoolCompat(sp, "flutter.use_target_size", false)
            var targetKb = spGetIntCompat(sp, "flutter.target_size_kb", 50).coerceAtLeast(50)
            settingsReadMs = SystemClock.elapsedRealtime() - settingsStartMs

            // 覆盖为每应用设置：从每应用 SQLite settings 读取（若 use_custom=true）
            try {
                val perAppStartMs = SystemClock.elapsedRealtime()
                val per = PerAppSettingsBridge.readQualitySettingsIfCustom(this, packageName)
                perAppReadMs = SystemClock.elapsedRealtime() - perAppStartMs
                if (per != null) {
                    format = per.format ?: format
                    quality = per.quality ?: quality
                    useTarget = per.useTargetSize ?: useTarget
                    targetKb = per.targetSizeKb ?: targetKb
                }
            } catch (_: Exception) {}

        // 可选灰度转换（不改变尺寸）
        val bitmap = src // 灰度已移除

        // 选择编码器
        val (cf, isLossy, isLossless, ext) = when (format) {
            "jpeg" -> ScreenshotProcessingQuad(Bitmap.CompressFormat.JPEG, true, false, "jpg")
            "png" -> ScreenshotProcessingQuad(Bitmap.CompressFormat.PNG, false, true, "png")
            "webp_lossless" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                ScreenshotProcessingQuad(Bitmap.CompressFormat.WEBP_LOSSLESS, false, true, "webp")
            } else {
                // 退化到 PNG 以确保无损
                ScreenshotProcessingQuad(Bitmap.CompressFormat.PNG, false, true, "png")
            }
            else -> { // webp_lossy
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    ScreenshotProcessingQuad(Bitmap.CompressFormat.WEBP_LOSSY, true, false, "webp")
                } else {
                    ScreenshotProcessingQuad(Bitmap.CompressFormat.WEBP, true, false, "webp")
                }
            }
        }

        FileLogger.i(TAG, "编码设置 -> format=${format}, lossy=${isLossy}, lossless=${isLossless}, quality=${quality}, useTarget=${useTarget}, targetKb=${targetKb}")

        // 目标大小仅在有损编码时生效
        if (isLossy && useTarget) {
            return try {
                val compressStartMs = SystemClock.elapsedRealtime()
                val quickQuality = 100
                val data = compressOnce(bitmap, cf, quickQuality)
                val compressMs = SystemClock.elapsedRealtime() - compressStartMs
                val spec = DeferredTargetCompressionSpec(
                    formatName = format,
                    compressFormat = cf,
                    targetBytes = targetKb * 1024,
                    fallbackQuality = 1,
                    targetKb = targetKb
                )
                FileLogger.i(TAG, "目标大小快速编码完成，精确压缩延后 -> 当前字节=${data.size}, 目标字节=${spec.targetBytes}")
                perf(
                    "trace=$traceId stage=encode result=ok mode=target_deferred format=$format ext=$ext " +
                        "quality=$quickQuality targetKb=$targetKb settingsReadMs=$settingsReadMs perAppReadMs=$perAppReadMs " +
                        "compressMs=$compressMs encodeTotalMs=${SystemClock.elapsedRealtime() - totalStartMs} bytes=${data.size}"
                )
                EncodedScreenshot(data, ext, spec)
            } catch (e: Exception) {
                perf(
                    "trace=$traceId stage=encode result=exception mode=target_deferred format=$format ext=$ext " +
                        "settingsReadMs=$settingsReadMs perAppReadMs=$perAppReadMs " +
                        "encodeTotalMs=${SystemClock.elapsedRealtime() - totalStartMs} message=${e.message ?: "-"}"
                )
                EncodedScreenshot(null, ext)
            }
        }

        // 否则按质量单次压缩；无损忽略质量
        return try {
            val appliedQ = if (isLossless) 100 else quality
            val compressStartMs = SystemClock.elapsedRealtime()
            val data = compressOnce(bitmap, cf, appliedQ)
            val compressMs = SystemClock.elapsedRealtime() - compressStartMs
            FileLogger.i(TAG, "单次编码完成 -> 实际字节=${data.size}, 格式=${format}, 质量=${appliedQ}")
            perf(
                "trace=$traceId stage=encode result=ok mode=single format=$format ext=$ext " +
                    "quality=$appliedQ settingsReadMs=$settingsReadMs perAppReadMs=$perAppReadMs " +
                    "compressMs=$compressMs encodeTotalMs=${SystemClock.elapsedRealtime() - totalStartMs} bytes=${data.size}"
            )
            EncodedScreenshot(data, ext)
        } catch (e: Exception) {
            perf(
                "trace=$traceId stage=encode result=exception format=$format ext=$ext " +
                    "settingsReadMs=$settingsReadMs perAppReadMs=$perAppReadMs " +
                    "encodeTotalMs=${SystemClock.elapsedRealtime() - totalStartMs} message=${e.message ?: "-"}"
            )
            EncodedScreenshot(null, ext)
        }
    }

    private data class ScreenshotProcessingQuad<A,B,C,D>(val a: A, val b: B, val c: C, val d: D)

    private fun compressOnce(bm: Bitmap, cf: Bitmap.CompressFormat, q: Int): ByteArray {
        val baos = java.io.ByteArrayOutputStream()
        bm.compress(cf, q.coerceIn(1,100), baos)
            return baos.toByteArray()
    }

    internal fun ScreenCaptureAccessibilityService.enqueueDeferredTargetCompression(
        file: File,
        relativePath: String,
        packageName: String,
        spec: DeferredTargetCompressionSpec,
        traceId: Long,
        initialBytes: Long
    ) {
        val pendingAfterEnqueue = pendingDeferredCompressions.incrementAndGet()
        try {
            perf(
                "trace=$traceId stage=deferred_compress_enqueue result=ok app=$packageName " +
                    "pending=$pendingAfterEnqueue initialBytes=$initialBytes targetBytes=${spec.targetBytes} path=$relativePath"
            )
            screenshotCompressionExecutor.execute {
                try {
                    runDeferredTargetCompression(file, relativePath, packageName, spec, traceId, initialBytes)
                } finally {
                    pendingDeferredCompressions.decrementAndGet()
                }
            }
        } catch (e: Exception) {
            pendingDeferredCompressions.decrementAndGet()
            perf(
                "trace=$traceId stage=deferred_compress_enqueue result=exception app=$packageName " +
                    "message=${e.message ?: "-"} path=$relativePath"
            )
            FileLogger.w(TAG, "提交延后精确压缩任务失败: ${e.message}")
        }
    }

    private fun ScreenCaptureAccessibilityService.runDeferredTargetCompression(
        file: File,
        relativePath: String,
        packageName: String,
        spec: DeferredTargetCompressionSpec,
        traceId: Long,
        initialBytes: Long
    ) {
        val totalStartMs = SystemClock.elapsedRealtime()
        var decodeMs = 0L
        var compressMs = 0L
        var writeMs = 0L
        var replaceMs = 0L
        var dbMs = 0L
        var notifyMs = 0L
        var decoded: Bitmap? = null
        val tmpFile = File(file.parentFile, "${file.name}.target.tmp")
        try {
            if (!file.exists()) {
                perf(
                    "trace=$traceId stage=deferred_compress result=skip reason=file_missing " +
                        "app=$packageName path=$relativePath"
                )
                return
            }

            val decodeStartMs = SystemClock.elapsedRealtime()
            decoded = BitmapFactory.decodeFile(file.absolutePath)
            decodeMs = SystemClock.elapsedRealtime() - decodeStartMs
            val bitmap = decoded
            if (bitmap == null) {
                perf(
                    "trace=$traceId stage=deferred_compress result=skip reason=decode_failed " +
                        "app=$packageName decodeMs=$decodeMs path=$relativePath"
                )
                return
            }

            val compressStartMs = SystemClock.elapsedRealtime()
            val targetBytes = compressToTargetSize(
                bitmap,
                spec.compressFormat,
                spec.targetBytes,
                minQ = 1,
                maxQ = 100
            ) ?: compressOnce(bitmap, spec.compressFormat, spec.fallbackQuality)
            compressMs = SystemClock.elapsedRealtime() - compressStartMs

            val writeStartMs = SystemClock.elapsedRealtime()
            FileOutputStream(tmpFile).use { out ->
                out.write(targetBytes)
                try {
                    out.fd.sync()
                } catch (_: Exception) {}
            }
            writeMs = SystemClock.elapsedRealtime() - writeStartMs

            val replaceStartMs = SystemClock.elapsedRealtime()
            try {
                Os.rename(tmpFile.absolutePath, file.absolutePath)
            } catch (_: Exception) {
                try {
                    FileOutputStream(file, false).use { out ->
                        out.write(targetBytes)
                        try {
                            out.fd.sync()
                        } catch (_: Exception) {}
                    }
                    tmpFile.delete()
                } catch (e: Exception) {
                    FileLogger.w(TAG, "延后精确压缩替换文件失败: ${e.message}")
                    throw e
                }
            }
            replaceMs = SystemClock.elapsedRealtime() - replaceStartMs

            val newSize = try { file.length() } catch (_: Exception) { targetBytes.size.toLong() }
            var nativeDbUpdated = false
            try {
                val dbStartMs = SystemClock.elapsedRealtime()
                nativeDbUpdated = ScreenshotDatabaseHelper.updateFileSizeByFilePath(
                    this,
                    file.absolutePath,
                    newSize
                )
                dbMs = SystemClock.elapsedRealtime() - dbStartMs
            } catch (e: Exception) {
                FileLogger.w(TAG, "延后精确压缩后更新原生文件大小失败: ${e.message}")
            }

            try {
                val notifyStartMs = SystemClock.elapsedRealtime()
                notifyScreenshotFileRecompressed(
                    packageName,
                    relativePath,
                    file.absolutePath,
                    newSize,
                    nativeDbUpdated,
                    traceId
                )
                notifyMs = SystemClock.elapsedRealtime() - notifyStartMs
            } catch (e: Exception) {
                FileLogger.w(TAG, "通知Flutter延后压缩完成失败: ${e.message}")
            }

            perf(
                "trace=$traceId stage=deferred_compress result=ok app=$packageName " +
                    "format=${spec.formatName} targetKb=${spec.targetKb} initialBytes=$initialBytes newBytes=$newSize " +
                    "decodeMs=$decodeMs compressMs=$compressMs writeMs=$writeMs replaceMs=$replaceMs dbMs=$dbMs notifyMs=$notifyMs " +
                    "totalMs=${SystemClock.elapsedRealtime() - totalStartMs} path=$relativePath"
            )
        } catch (e: Exception) {
            perf(
                "trace=$traceId stage=deferred_compress result=exception app=$packageName " +
                    "message=${e.message ?: "-"} decodeMs=$decodeMs compressMs=$compressMs writeMs=$writeMs " +
                    "replaceMs=$replaceMs totalMs=${SystemClock.elapsedRealtime() - totalStartMs} path=$relativePath"
            )
        } finally {
            try { decoded?.recycle() } catch (_: Exception) {}
            try { if (tmpFile.exists()) tmpFile.delete() } catch (_: Exception) {}
        }
    }

    /**
     * 二分质量以尽量接近目标大小（仅 lossy）。
     */
    private fun compressToTargetSize(bm: Bitmap, cf: Bitmap.CompressFormat, targetBytes: Int, minQ: Int, maxQ: Int): ByteArray? {
        var lo = minQ.coerceIn(1, 100)
        var hi = maxQ.coerceIn(lo, 100)
        var bestUnder: ByteArray? = null
        var bestOver: ByteArray? = null
        var iterations = 0
        while (lo <= hi && iterations < 12) {
            iterations++
            val mid = (lo + hi) / 2
            val data = compressOnce(bm, cf, mid)
            FileLogger.d(TAG, "压缩二分 -> 第${iterations}次, q=${mid}, size=${data.size}, target=${targetBytes}")
            if (data.size <= targetBytes) {
                // 记录当前最接近目标的“不过线”方案，继续提高质量以更接近目标
                if (bestUnder == null || data.size > bestUnder.size) bestUnder = data
                lo = mid + 1
            } else {
                // 记录当前最小的“超过目标”方案，降低质量
                if (bestOver == null || data.size < bestOver.size) bestOver = data
                hi = mid - 1
            }
        }
        val result = bestUnder ?: bestOver
        if (result != null) {
            FileLogger.i(TAG, "压缩二分完成 -> 最终size=${result.size}, 目标=${targetBytes}")
        } else {
            FileLogger.w(TAG, "压缩二分未找到合适质量")
        }
        return result
    }

    internal fun spGetIntCompat(sp: android.content.SharedPreferences, key: String, def: Int): Int {
        return try {
            val any = sp.all[key]
            when (any) {
                is Int -> any
                is Long -> {
                    if (any > Int.MAX_VALUE) Int.MAX_VALUE else if (any < Int.MIN_VALUE) Int.MIN_VALUE else any.toInt()
                }
                is Float -> any.toInt()
                is Double -> {
                    if (any > Int.MAX_VALUE) Int.MAX_VALUE else if (any < Int.MIN_VALUE) Int.MIN_VALUE else any.toInt()
                }
                is String -> any.toDoubleOrNull()?.toInt() ?: def
                else -> try { sp.getInt(key, def) } catch (_: Exception) { def }
            }
        } catch (_: Exception) { def }
    }

    internal fun spGetBoolCompat(sp: android.content.SharedPreferences, key: String, def: Boolean): Boolean {
        return try {
            val any = sp.all[key]
            when (any) {
                is Boolean -> any
                is String -> any.equals("true", ignoreCase = true)
                is Int -> any != 0
                is Long -> any != 0L
                else -> sp.getBoolean(key, def)
            }
        } catch (_: Exception) { def }
    }

    private fun toGrayscale(src: Bitmap): Bitmap {
        return try {
            val w = src.width
            val h = src.height
            val gray = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val c = Canvas(gray)
            val paint = Paint()
            val cm = ColorMatrix()
            cm.setSaturation(0f)
            paint.colorFilter = ColorMatrixColorFilter(cm)
            c.drawBitmap(src, 0f, 0f, paint)
            gray
        } catch (_: Exception) { src }
    }
