import java.util.Properties
import java.io.FileInputStream
import java.security.MessageDigest

plugins {
    id("com.android.application")
    // AGP 9: this module's Kotlin (MainActivity etc.) is compiled by AGP's
    // built-in Kotlin. The per-module opt-in plugin is used because
    // android.builtInKotlin must stay false globally while unmigrated plugin
    // modules (veil_flutter, hidden_volume, file_picker, ...) still apply the
    // legacy Kotlin Android plugin — see android/settings.gradle.kts.
    id("com.android.built-in-kotlin")
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
// not source. It is NO LONGER BUNDLED BY DEFAULT: it did not compress, so it
// was 63% of the download (89.7 MiB against 32.7 MiB without) for a feature
// most people never use. The app fetches it on demand instead, verifying the
// same size and SHA-256 pinned below, and stores it once for the whole app.
//
// Bundling stays available for a build meant to install without a network:
// set XVEIL_BUNDLE_WHISPER_MODEL=1. That path still fails closed on a missing
// or unexpected file, because a bundled-but-wrong model is worse than none.
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
        val bundleRequested =
            providers.environmentVariable("XVEIL_BUNDLE_WHISPER_MODEL")
                .orNull == "1"
        val explicitlyRequired =
            providers.environmentVariable("XVEIL_REQUIRE_WHISPER_MODEL")
                .orNull == "1" || bundleRequested
        if (!whisperNativeLibrary.isFile) {
            val message =
                "xVeil: ${whisperNativeLibrary.absolutePath} is missing; run " +
                    "native/whisper/build_veil_whisper_android.sh"
            val releaseRequested = gradle.startParameter.taskNames.any {
                it.contains("release", ignoreCase = true)
            }
            if (releaseRequested || explicitlyRequired) throw GradleException(message)
            logger.warn("$message (debug build will omit transcription)")
        }
        if (!bundleRequested) {
            // The default: the app downloads the model on first use.
            logger.lifecycle(
                "xVeil: $whisperModelName not bundled (set " +
                    "XVEIL_BUNDLE_WHISPER_MODEL=1 for an offline-installable " +
                    "build); the app fetches it on demand",
            )
            return@doLast
        }
        if (source == null) {
            val message =
                "xVeil: $whisperModelName is missing; set " +
                    "XVEIL_WHISPER_MODEL_SRC or run " +
                    "native/whisper/build_veil_whisper_android.sh"
            throw GradleException(message)
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

    // AGP 9 rejects Provider instances in the legacy SourceSet API. Resolve the
    // generated dir eagerly instead: the producing task is wired explicitly
    // below (preBuild dependsOn prepareWhisperModel), so no implicit task
    // dependency is lost by handing over a plain path.
    sourceSets.getByName("main").assets.srcDir(generatedWhisperAssets.get().asFile)
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

    packaging {
        jniLibs {
            // Same behavior the manifest used to request via
            // android:extractNativeLibs="true" (native libs compressed in the
            // APK and extracted at install). AGP 9 rejects the explicit
            // manifest attribute and requires expressing it here instead; the
            // merged manifest still ends up with extractNativeLibs="true".
            useLegacyPackaging = true
        }
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
