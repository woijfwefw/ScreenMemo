import org.gradle.api.GradleException
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Locale
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()

fun requireKeystoreProperty(name: String): String =
    keystoreProperties.getProperty(name)
        ?: throw GradleException("Missing `$name` in ${keystorePropertiesFile.path}.")

if (hasReleaseKeystore) {
    keystorePropertiesFile.reader(Charsets.UTF_8).use { keystoreProperties.load(it) }
    // 兼容 Windows PowerShell 5 生成的 UTF-8 BOM 文件，避免首个属性名带 BOM。
    val normalizedProperties = Properties()
    keystoreProperties.forEach { key, value ->
        normalizedProperties.setProperty(
            key.toString().removePrefix("\uFEFF"),
            value.toString()
        )
    }
    keystoreProperties.clear()
    keystoreProperties.putAll(normalizedProperties)
}

val requiredReleaseSigningProperties = listOf(
    "storePassword",
    "keyPassword",
    "keyAlias",
    "storeFile",
)

fun normalizeSha256(value: String?): String? {
    val hex = value
        ?.lowercase(Locale.ROOT)
        ?.filter { it in '0'..'9' || it in 'a'..'f' }
        ?: return null
    val normalized = if (hex.length > 64) hex.takeLast(64) else hex
    return normalized.takeIf { it.isNotBlank() }
}

val expectedReleaseCertSha256 = normalizeSha256(
    keystoreProperties.getProperty("certSha256") ?: System.getenv("ANDROID_SIGNING_CERT_SHA256")
)

fun releaseStoreFile(): java.io.File = file(requireKeystoreProperty("storeFile"))

fun releaseCertificateSha256(): String {
    val storeType = keystoreProperties.getProperty("storeType", KeyStore.getDefaultType())
    val keyStore = KeyStore.getInstance(storeType)
    releaseStoreFile().inputStream().use { input ->
        keyStore.load(input, requireKeystoreProperty("storePassword").toCharArray())
    }
    val certificate = keyStore.getCertificate(requireKeystoreProperty("keyAlias"))
        ?: throw GradleException("Missing signing certificate for keyAlias `${requireKeystoreProperty("keyAlias")}`.")
    val digest = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
    return digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

fun validateReleaseSigningConfig(): String {
    if (!hasReleaseKeystore) {
        throw GradleException(
            "Release signing is required. Create android/key.properties and point it to the stable release keystore."
        )
    }

    val missingProperties = requiredReleaseSigningProperties.filter {
        keystoreProperties.getProperty(it).isNullOrBlank()
    }
    if (missingProperties.isNotEmpty()) {
        throw GradleException(
            "Missing Android signing properties in ${keystorePropertiesFile.path}: ${missingProperties.joinToString(", ")}."
        )
    }

    val storeFile = releaseStoreFile()
    if (!storeFile.isFile) {
        throw GradleException("Android signing storeFile does not exist: ${storeFile.path}.")
    }

    val actualSha256 = releaseCertificateSha256()
    if (expectedReleaseCertSha256 != null && expectedReleaseCertSha256.length != 64) {
        throw GradleException("Android signing certificate SHA-256 must contain 64 hex characters.")
    }
    if (expectedReleaseCertSha256 != null && actualSha256 != expectedReleaseCertSha256) {
        throw GradleException(
            "Android signing certificate mismatch. Expected $expectedReleaseCertSha256 but found $actualSha256."
        )
    }
    return actualSha256
}

android {
    namespace = "com.fqyw.screen_memo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"
    
    buildFeatures {
        aidl = true
    }

    compileOptions {
        // 启用 desugaring 以支持 Java 8+ 语言/库特性（满足 flutter_local_notifications 要求）
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    lint {
        // Windows 上 release 构建偶发命中 lint cache 文件锁，导致
        // `lintVitalAnalyzeRelease` 失败并阻塞发包；这里关闭 release lint gate，
        // 保证正式打包不被该缓存锁问题卡住。
        checkReleaseBuilds = false
        abortOnError = false
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.fqyw.screen_memo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                keyAlias = requireKeystoreProperty("keyAlias")
                keyPassword = requireKeystoreProperty("keyPassword")
                storeFile = file(requireKeystoreProperty("storeFile"))
                storePassword = requireKeystoreProperty("storePassword")
                storeType = keystoreProperties.getProperty("storeType")
            }
        }
    }

    buildTypes {
        configureEach {
            // 本地配置了正式 keystore 时，debug/profile 等开发构建也使用同一签名，
            // 方便直接覆盖 GitHub Release 版本做真机调试。
            if (name != "release" && hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
        }

        release {
            // Release 包必须使用稳定正式签名，禁止退回 debug keystore。
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

val validateReleaseSigning by tasks.registering {
    group = "verification"
    description = "Validates the stable Android release signing certificate."
    doLast {
        val sha256 = validateReleaseSigningConfig()
        logger.lifecycle("Android signing certificate SHA-256: $sha256")
    }
}

tasks.configureEach {
    val taskName = name.lowercase(Locale.ROOT)
    val isPackagingTask =
        taskName.startsWith("assemble") ||
            taskName.startsWith("bundle") ||
            taskName.startsWith("package")
    val isReleasePackagingTask = isPackagingTask && taskName.contains("release")

    // release 打包必须校验；本地存在 key.properties 时，debug/profile 打包也校验，防止误用其他签名。
    if (isReleasePackagingTask || (hasReleaseKeystore && isPackagingTask)) {
        dependsOn(validateReleaseSigning)
    }
}

dependencies {
    // Satisfy Flutter deferred components references during R8 shrinking
    implementation("com.google.android.play:core:1.10.3")

    // 启用核心库 desugaring（满足 flutter_local_notifications 的 AAR 要求）
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // OkHttp：用于每日总结/分段上传等 HTTP 调用
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // ML Kit: 中文文本识别（离线模型随 APK 打包）
    implementation("com.google.mlkit:text-recognition-chinese:16.0.0")

    // WorkManager：后台每日总结生成
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // XLog：高性能日志（控制台/多 Printer，可替代原生 Log.* 控制台输出）
    implementation("com.elvishew:xlog:1.11.1")

    // 协程：后台事件处理与流式更新
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Lifecycle：为服务和 Application 提供协程生命周期支持
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-service:2.8.4")

    // Unit tests
    testImplementation("junit:junit:4.13.2")
    testImplementation("io.mockk:mockk:1.13.12")
    // Use JVM org.json to avoid "not mocked" stubs in local unit tests
    testImplementation("org.json:json:20231013")
}
