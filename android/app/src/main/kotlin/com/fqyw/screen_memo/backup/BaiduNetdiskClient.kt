package com.fqyw.screen_memo.backup

import android.content.Context
import com.fqyw.screen_memo.logging.FileLogger
import com.fqyw.screen_memo.network.OkHttpClientFactory
import com.fqyw.screen_memo.settings.UserSettingsKeysNative
import com.fqyw.screen_memo.settings.UserSettingsStorage
import okhttp3.FormBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okio.BufferedSink
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

data class BaiduTokenSet(
    val accessToken: String,
    val refreshToken: String,
    val expiresAtMillis: Long,
)

data class BaiduUploadProgress(
    val stage: String,
    val bytesDone: Long = 0L,
    val bytesTotal: Long = 0L,
    val detail: String = "",
)

class BaiduNetdiskClient(
    private val context: Context,
    private val httpClient: OkHttpClient = OkHttpClientFactory.newBuilder(context)
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(90, TimeUnit.SECONDS)
        .writeTimeout(90, TimeUnit.SECONDS)
        .build(),
) {
    private val appContext = context.applicationContext

    fun exchangeCode(code: String): BaiduTokenSet {
        val appKey = requireSetting(UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_APP_KEY, "AppKey is required.")
        val secretKey = requireSetting(UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_SECRET_KEY, "SecretKey is required.")
        val url = OAUTH_TOKEN_URL.toHttpUrl().newBuilder()
            .addQueryParameter("grant_type", "authorization_code")
            .addQueryParameter("code", code)
            .addQueryParameter("client_id", appKey)
            .addQueryParameter("client_secret", secretKey)
            .addQueryParameter("redirect_uri", "oob")
            .build()
        val json = executeJson(Request.Builder().url(url).baiduGet().build())
        val token = parseToken(json)
        saveToken(token)
        return token
    }

    fun ensureAccessToken(): String {
        val appKey = requireSetting(UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_APP_KEY, "AppKey is required.")
        val secretKey = requireSetting(UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_SECRET_KEY, "SecretKey is required.")
        val accessToken = UserSettingsStorage.getString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_ACCESS_TOKEN,
            "",
        ).orEmpty()
        val refreshToken = UserSettingsStorage.getString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_REFRESH_TOKEN,
            "",
        ).orEmpty()
        val expiresAt = UserSettingsStorage.getString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_TOKEN_EXPIRES_AT,
            "0",
        )?.toLongOrNull() ?: 0L
        val refreshBefore = System.currentTimeMillis() + 24L * 60L * 60L * 1000L
        if (accessToken.isNotBlank() && expiresAt > refreshBefore) {
            return accessToken
        }
        if (refreshToken.isBlank()) {
            throw IllegalStateException("Authorization is required.")
        }
        try {
            val url = OAUTH_TOKEN_URL.toHttpUrl().newBuilder()
                .addQueryParameter("grant_type", "refresh_token")
                .addQueryParameter("refresh_token", refreshToken)
                .addQueryParameter("client_id", appKey)
                .addQueryParameter("client_secret", secretKey)
                .build()
            val json = executeJson(Request.Builder().url(url).baiduGet().build())
            val token = parseToken(json)
            saveToken(token)
            return token.accessToken
        } catch (e: Exception) {
            clearToken()
            UserSettingsStorage.putString(
                appContext,
                UserSettingsKeysNative.CLOUD_BACKUP_LAST_STATUS,
                "authorization_required",
            )
            throw IllegalStateException("Authorization is required.", e)
        }
    }

    fun testConnection(deviceId: String): Map<String, Any?> {
        val token = ensureAccessToken()
        val dir = backupDir(deviceId)
        ensureRemoteFolder(token, dir)
        val files = listRemoteBackups(token, dir)
        return mapOf("ok" to true, "dir" to dir, "remoteBackupCount" to files.size)
    }

    fun uploadBackup(
        file: File,
        deviceId: String,
        keepLatestCount: Int,
        onProgress: ((BaiduUploadProgress) -> Unit)? = null,
    ): Map<String, Any?> {
        val token = ensureAccessToken()
        val dir = backupDir(deviceId)
        onProgress?.invoke(BaiduUploadProgress(stage = "remote_folder", detail = dir))
        ensureRemoteFolder(token, dir)
        val remotePath = "$dir/${file.name}"
        uploadFile(token, file, remotePath, onProgress)
        onProgress?.invoke(BaiduUploadProgress(stage = "cleanup", detail = dir))
        cleanupRemoteBackups(token, dir, keepLatestCount)
        return mapOf("ok" to true, "remotePath" to remotePath, "size" to file.length())
    }

    fun cleanupRemoteBackups(token: String, dir: String, keepLatestCount: Int) {
        val files = listRemoteBackups(token, dir)
        val toDelete = CloudBackupPolicy.selectBackupsToDelete(files, keepLatestCount)
        if (toDelete.isEmpty()) return
        deleteFiles(token, toDelete.map { it.path })
        FileLogger.i(TAG, "云端备份清理完成：deleted=${toDelete.size}")
    }

    private fun uploadFile(
        token: String,
        file: File,
        remotePath: String,
        onProgress: ((BaiduUploadProgress) -> Unit)? = null,
    ) {
        if (!file.exists() || !file.isFile) {
            throw IllegalArgumentException("Backup file does not exist.")
        }
        onProgress?.invoke(
            BaiduUploadProgress(
                stage = "preparing_upload",
                bytesTotal = file.length(),
                detail = remotePath,
            ),
        )
        val blockSize = chooseBlockSize()
        val blockMd5List = computeBlockMd5List(file, blockSize)
        val contentMd5 = md5Hex(file)
        val sliceMd5 = md5Hex(file, maxBytes = 256L * 1024L)
        val blockListJson = JSONArray(blockMd5List).toString()
        onProgress?.invoke(
            BaiduUploadProgress(
                stage = "precreate",
                bytesTotal = file.length(),
                detail = file.name,
            ),
        )
        val precreate = precreate(token, remotePath, file.length(), blockListJson, contentMd5, sliceMd5)
        val uploadId = precreate.optString("uploadid")
        if (uploadId.isBlank()) {
            throw IllegalStateException("Baidu precreate did not return uploadid.")
        }
        val uploadServer = locateUploadServer(token, remotePath, uploadId)
        val requested = parseRequestedBlocks(precreate, blockMd5List.size)
        val uploadedBlocks = mutableSetOf<Int>()
        for (partSeq in requested) {
            uploadPart(uploadServer, token, remotePath, uploadId, file, partSeq, blockSize)
            uploadedBlocks.add(partSeq)
            val bytesDone = uploadedBlocks.sumOf { index ->
                val offset = index.toLong() * blockSize
                minOf(blockSize, file.length() - offset).coerceAtLeast(0L)
            }.coerceAtMost(file.length())
            onProgress?.invoke(
                BaiduUploadProgress(
                    stage = "uploading",
                    bytesDone = bytesDone,
                    bytesTotal = file.length(),
                    detail = "${uploadedBlocks.size}/${requested.size}",
                ),
            )
        }
        onProgress?.invoke(
            BaiduUploadProgress(
                stage = "create",
                bytesDone = file.length(),
                bytesTotal = file.length(),
                detail = remotePath,
            ),
        )
        createFile(token, remotePath, file.length(), blockListJson, uploadId)
    }

    private fun precreate(
        token: String,
        remotePath: String,
        size: Long,
        blockListJson: String,
        contentMd5: String,
        sliceMd5: String,
    ): JSONObject {
        val url = XPAN_FILE_URL.toHttpUrl().newBuilder()
            .addQueryParameter("method", "precreate")
            .addQueryParameter("access_token", token)
            .build()
        val body = FormBody.Builder()
            .add("path", remotePath)
            .add("size", size.toString())
            .add("isdir", "0")
            .add("autoinit", "1")
            .add("rtype", "3")
            .add("block_list", blockListJson)
            .add("content-md5", contentMd5)
            .add("slice-md5", sliceMd5)
            .build()
        val json = executeJson(Request.Builder().url(url).baiduPost(body).build())
        ensureErrnoOk(json, "precreate")
        return json
    }

    private fun locateUploadServer(token: String, remotePath: String, uploadId: String): String {
        val url = LOCATE_UPLOAD_URL.toHttpUrl().newBuilder()
            .addQueryParameter("method", "locateupload")
            .addQueryParameter("appid", "250528")
            .addQueryParameter("access_token", token)
            .addQueryParameter("path", remotePath)
            .addQueryParameter("uploadid", uploadId)
            .addQueryParameter("upload_version", "2.0")
            .build()
        val json = executeJson(Request.Builder().url(url).baiduGet().build())
        val errorCode = json.optInt("error_code", 0)
        if (errorCode != 0) {
            throw IllegalStateException(
                "Baidu locate upload server failed: error_code=$errorCode ${json.optString("error_msg")}",
            )
        }
        val servers = json.optJSONArray("servers") ?: JSONArray()
        for (i in 0 until servers.length()) {
            val server = servers.optJSONObject(i)?.optString("server").orEmpty()
            if (server.startsWith("https://", ignoreCase = true)) {
                return server.trimEnd('/')
            }
        }
        throw IllegalStateException("Baidu locate upload server did not return an HTTPS server.")
    }

    private fun uploadPart(
        uploadServer: String,
        token: String,
        remotePath: String,
        uploadId: String,
        file: File,
        partSeq: Int,
        blockSize: Long,
    ) {
        val offset = partSeq.toLong() * blockSize
        val length = minOf(blockSize, file.length() - offset)
        val url = "$uploadServer/rest/2.0/pcs/superfile2".toHttpUrl().newBuilder()
            .addQueryParameter("method", "upload")
            .addQueryParameter("access_token", token)
            .addQueryParameter("type", "tmpfile")
            .addQueryParameter("path", remotePath)
            .addQueryParameter("uploadid", uploadId)
            .addQueryParameter("partseq", partSeq.toString())
            .build()
        val partBody = FileChunkRequestBody(file, offset, length)
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("file", file.name, partBody)
            .build()
        val json = executeJson(Request.Builder().url(url).baiduPost(body).build())
        ensureErrnoOk(json, "upload part $partSeq")
    }

    private fun createFile(
        token: String,
        remotePath: String,
        size: Long,
        blockListJson: String,
        uploadId: String,
    ) {
        val url = XPAN_FILE_URL.toHttpUrl().newBuilder()
            .addQueryParameter("method", "create")
            .addQueryParameter("access_token", token)
            .build()
        val nowSec = (System.currentTimeMillis() / 1000L).toString()
        val body = FormBody.Builder()
            .add("path", remotePath)
            .add("size", size.toString())
            .add("isdir", "0")
            .add("rtype", "3")
            .add("uploadid", uploadId)
            .add("block_list", blockListJson)
            .add("local_ctime", nowSec)
            .add("local_mtime", nowSec)
            .add("mode", "3")
            .build()
        val json = executeJson(Request.Builder().url(url).baiduPost(body).build())
        ensureErrnoOk(json, "create")
    }

    private fun ensureRemoteFolder(token: String, dir: String) {
        val parts = dir.trim('/').split('/').filter { it.isNotBlank() }
        if (parts.size >= 2 && parts[0] == "apps") {
            var current = "/apps/${parts[1]}"
            createFolder(token, current)
            for (part in parts.drop(2)) {
                current += "/$part"
                createFolder(token, current)
            }
            return
        }
        var current = ""
        for (part in parts) {
            current += "/$part"
            createFolder(token, current)
        }
    }

    private fun createFolder(token: String, path: String) {
        val url = XPAN_FILE_URL.toHttpUrl().newBuilder()
            .addQueryParameter("method", "create")
            .addQueryParameter("access_token", token)
            .build()
        val body = FormBody.Builder()
            .add("path", path)
            .add("size", "0")
            .add("isdir", "1")
            .add("rtype", "0")
            .add("block_list", "[]")
            .build()
        val json = executeJson(Request.Builder().url(url).baiduPost(body).build())
        val errno = json.optInt("errno", 0)
        if (errno != 0 && errno != -8) {
            throw IllegalStateException("Baidu create folder failed: errno=$errno path=$path")
        }
    }

    private fun listRemoteBackups(token: String, dir: String): List<RemoteBackupFile> {
        val url = XPAN_FILE_URL.toHttpUrl().newBuilder()
            .addQueryParameter("method", "list")
            .addQueryParameter("access_token", token)
            .addQueryParameter("dir", dir)
            .addQueryParameter("order", "time")
            .addQueryParameter("desc", "1")
            .addQueryParameter("start", "0")
            .addQueryParameter("limit", "1000")
            .build()
        val json = executeJson(Request.Builder().url(url).baiduGet().build())
        val errno = json.optInt("errno", 0)
        if (errno != 0) {
            throw IllegalStateException("Baidu list failed: errno=$errno")
        }
        val arr = json.optJSONArray("list") ?: JSONArray()
        val result = mutableListOf<RemoteBackupFile>()
        for (i in 0 until arr.length()) {
            val item = arr.optJSONObject(i) ?: continue
            result.add(
                RemoteBackupFile(
                    path = item.optString("path"),
                    name = item.optString("server_filename", item.optString("path").substringAfterLast('/')),
                    mtime = item.optLong("mtime", item.optLong("server_mtime", 0L)),
                    isDir = item.optInt("isdir", 0) == 1,
                ),
            )
        }
        return result
    }

    private fun deleteFiles(token: String, paths: List<String>) {
        if (paths.isEmpty()) return
        val url = XPAN_FILE_URL.toHttpUrl().newBuilder()
            .addQueryParameter("method", "filemanager")
            .addQueryParameter("access_token", token)
            .addQueryParameter("opera", "delete")
            .build()
        val body = FormBody.Builder()
            .add("async", "0")
            .add("filelist", JSONArray(paths).toString())
            .build()
        val json = executeJson(Request.Builder().url(url).baiduPost(body).build())
        ensureErrnoOk(json, "delete")
    }

    private fun parseRequestedBlocks(json: JSONObject, fallbackCount: Int): List<Int> {
        val arr = json.optJSONArray("block_list")
        if (arr == null || arr.length() == 0) {
            return (0 until fallbackCount).toList()
        }
        val result = mutableListOf<Int>()
        for (i in 0 until arr.length()) {
            result.add(arr.optInt(i))
        }
        return result.ifEmpty { (0 until fallbackCount).toList() }
    }

    private fun executeJson(request: Request): JSONObject {
        httpClient.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}: ${text.take(200)}")
            }
            val json = JSONObject(text.ifBlank { "{}" })
            if (json.has("error")) {
                throw IllegalStateException(
                    json.optString("error_description", json.optString("error")),
                )
            }
            return json
        }
    }

    private fun ensureErrnoOk(json: JSONObject, stage: String) {
        val errno = json.optInt("errno", 0)
        if (errno != 0) {
            throw IllegalStateException("Baidu $stage failed: errno=$errno")
        }
    }

    private fun parseToken(json: JSONObject): BaiduTokenSet {
        val accessToken = json.optString("access_token")
        val refreshToken = json.optString("refresh_token")
        val expiresIn = json.optLong("expires_in", 0L)
        if (accessToken.isBlank() || refreshToken.isBlank() || expiresIn <= 0L) {
            throw IllegalStateException("Baidu token response is incomplete.")
        }
        return BaiduTokenSet(
            accessToken = accessToken,
            refreshToken = refreshToken,
            expiresAtMillis = System.currentTimeMillis() + expiresIn * 1000L,
        )
    }

    private fun saveToken(token: BaiduTokenSet) {
        UserSettingsStorage.putString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_ACCESS_TOKEN,
            token.accessToken,
        )
        UserSettingsStorage.putString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_REFRESH_TOKEN,
            token.refreshToken,
        )
        UserSettingsStorage.putString(
            appContext,
            UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_TOKEN_EXPIRES_AT,
            token.expiresAtMillis.toString(),
        )
    }

    private fun clearToken() {
        UserSettingsStorage.putString(appContext, UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_ACCESS_TOKEN, "")
        UserSettingsStorage.putString(appContext, UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_REFRESH_TOKEN, "")
        UserSettingsStorage.putString(appContext, UserSettingsKeysNative.CLOUD_BACKUP_BAIDU_TOKEN_EXPIRES_AT, "0")
    }

    private fun requireSetting(key: String, message: String): String {
        val value = UserSettingsStorage.getString(appContext, key, "").orEmpty().trim()
        if (value.isBlank()) throw IllegalStateException(message)
        return value
    }

    private fun computeBlockMd5List(file: File, blockSize: Long): List<String> {
        val result = mutableListOf<String>()
        var offset = 0L
        while (offset < file.length()) {
            val length = minOf(blockSize, file.length() - offset)
            result.add(md5Hex(file, offset, length))
            offset += blockSize
        }
        return result.ifEmpty { listOf(md5Hex(file)) }
    }

    private fun md5Hex(file: File, offset: Long = 0L, maxBytes: Long = Long.MAX_VALUE): String {
        val digest = MessageDigest.getInstance("MD5")
        RandomAccessFile(file, "r").use { raf ->
            raf.seek(offset)
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var remaining = minOf(maxBytes, file.length() - offset)
            while (remaining > 0) {
                val read = raf.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read <= 0) break
                digest.update(buffer, 0, read)
                remaining -= read.toLong()
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun chooseBlockSize(): Long {
        // 百度 precreate 的 block_list 仍按 4MB 切片定义；统一 4MB 兼容普通用户、会员和 SVIP。
        return UPLOAD_BLOCK_SIZE_BYTES
    }

    private fun backupDir(deviceId: String): String {
        val safe = deviceId.replace(Regex("[^A-Za-z0-9_.-]"), "_").ifBlank { "device" }
        return "/apps/ScreenMemo/backups/devices/$safe/full"
    }

    private fun Request.Builder.baiduGet(): Request.Builder {
        return get().header("User-Agent", "pan.baidu.com")
    }

    private fun Request.Builder.baiduPost(body: RequestBody): Request.Builder {
        return post(body).header("User-Agent", "pan.baidu.com")
    }

    private class FileChunkRequestBody(
        private val file: File,
        private val offset: Long,
        private val length: Long,
    ) : RequestBody() {
        override fun contentType() = "application/octet-stream".toMediaTypeOrNull()

        override fun contentLength(): Long = length

        override fun writeTo(sink: BufferedSink) {
            RandomAccessFile(file, "r").use { raf ->
                raf.seek(offset)
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var remaining = length
                while (remaining > 0) {
                    val read = raf.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                    if (read <= 0) break
                    sink.write(buffer, 0, read)
                    remaining -= read.toLong()
                }
            }
        }
    }

    companion object {
        private const val TAG = "BaiduNetdiskClient"
        private const val OAUTH_TOKEN_URL = "https://openapi.baidu.com/oauth/2.0/token"
        private const val XPAN_FILE_URL = "https://pan.baidu.com/rest/2.0/xpan/file"
        private const val LOCATE_UPLOAD_URL = "https://d.pcs.baidu.com/rest/2.0/pcs/file"
        private const val UPLOAD_BLOCK_SIZE_BYTES = 4L * 1024L * 1024L
    }
}
