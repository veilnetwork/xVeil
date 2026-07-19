import java.util.Properties
import java.io.FileInputStream
import java.security.MessageDigest

plugins {
    id("com.android.application")
    // MainActivity is Kotlin and AGP 8 does not provide built-in Kotlin, so
    // the app module must apply the Kotlin plugin explicitly.
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material is read from key.properties (gitignored — alongside
// the keystore it points at), so the signing key never enters the repo. When the
// file is absent (a dev box doing `flutter run --release`) we fall back to the
// debug key; a real distributable build MUST provide key.properties so it is NOT
// debug-signed. See android/.gitignore (key.properties / *.jks / *.keystore).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// whisper.cpp's quantized model is a generated distribution artifact (~57 MiB),
// not source. Package it from an explicit CI path, the repo-local generated
// location, or the conventional sibling whisper.cpp checkout. Release builds
// fail closed when it is absent or has unexpected bytes: shipping a build with
// a visible-but-non-functional transcription feature is worse than a loud
// packaging failure.
val whisperModelName = "ggml-base-q5_1.bin"
val whisperModelSha256 =
    "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
val whisperModelSize = 59_707_625L
val whisperModelSource = sequenceOf(
    providers.environmentVariable("XVEIL_WHISPER_MODEL_SRC").orNull?.let(::file),
    rootProject.file("../native/whisper/models/$whisperModelName"),
    rootProject.file("../../whisper.cpp/models/$whisperModelName"),
).filterNotNull().firstOrNull { it.isFile }
val whisperNativeLibrary = file("src/main/jniLibs/arm64-v8a/libveil_whisper.so")
val generatedWhisperAssets = layout.buildDirectory.dir("generated/whisperAssets")

val prepareWhisperModel by tasks.registering {
    val outputDir = generatedWhisperAssets
    inputs.property("modelPath", whisperModelSource?.absolutePath ?: "missing")
    inputs.property(
        "nativeLibraryPath",
        if (whisperNativeLibrary.isFile) whisperNativeLibrary.absolutePath else "missing",
    )
    whisperModelSource?.let { inputs.file(it) }
    outputs.dir(outputDir)

    doLast {
        val destinationDir = outputDir.get().asFile
        delete(destinationDir)
        val source = whisperModelSource
        val releaseRequested = gradle.startParameter.taskNames.any {
            it.contains("release", ignoreCase = true)
        }
        val explicitlyRequired =
            providers.environmentVariable("XVEIL_REQUIRE_WHISPER_MODEL")
                .orNull == "1"
        if (!whisperNativeLibrary.isFile) {
            val message =
                "xVeil: ${whisperNativeLibrary.absolutePath} is missing; run " +
                    "native/whisper/build_veil_whisper_android.sh"
            if (releaseRequested || explicitlyRequired) throw GradleException(message)
            logger.warn("$message (debug build will omit transcription)")
        }
        if (source == null) {
            val message =
                "xVeil: $whisperModelName is missing; set " +
                    "XVEIL_WHISPER_MODEL_SRC or run " +
                    "native/whisper/build_veil_whisper_android.sh"
            if (releaseRequested || explicitlyRequired) throw GradleException(message)
            logger.warn("$message (debug build will omit transcription)")
            return@doLast
        }
        if (source.length() != whisperModelSize) {
            throw GradleException(
                "xVeil: unexpected $whisperModelName size: " +
                    "${source.length()} (expected $whisperModelSize)",
            )
        }
        val digest = MessageDigest.getInstance("SHA-256")
        source.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE * 16)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val actualSha = digest.digest().joinToString("") { "%02x".format(it) }
        if (actualSha != whisperModelSha256) {
            throw GradleException(
                "xVeil: $whisperModelName SHA-256 $actualSha does not match " +
                    whisperModelSha256,
            )
        }
        destinationDir.mkdirs()
        source.copyTo(destinationDir.resolve(whisperModelName), overwrite = true)
        logger.lifecycle(
            "xVeil: bundled $whisperModelName (${source.length()} bytes, SHA-256 verified)",
        )
    }
}

android {
    namespace = "network.veil.xveil"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    sourceSets.getByName("main").assets.srcDir(generatedWhisperAssets)
    androidResources {
        // The quantized model is already entropy-dense. Keeping it uncompressed
        // avoids an expensive inflate pass before the one-time private install.
        noCompress += "bin"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (uses java.time on older API
        // levels): backport the desugared JDK libs.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "network.veil.xveil"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Only declare the release config when key.properties is present;
        // referencing missing properties would fail configuration on a dev box.
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Real release: sign with the provided keystore. Dev box without
            // key.properties: fall back to debug so `flutter run --release` works
            // (such a build is NOT distributable — it is debug-signed).
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "xVeil: key.properties not found — release build is " +
                        "DEBUG-SIGNED and must not be distributed.",
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(prepareWhisperModel)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backports java.time etc. for flutter_local_notifications (see
    // isCoreLibraryDesugaringEnabled above).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
