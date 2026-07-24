pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 9 migration (gradual built-in-Kotlin scheme, see
    // https://developer.android.com/build/migrate-to-built-in-kotlin):
    //   * :app compiles Kotlin via AGP's built-in Kotlin — it applies the
    //     per-module com.android.built-in-kotlin plugin (same version as AGP)
    //     instead of the legacy org.jetbrains.kotlin.android plugin.
    //   * android.builtInKotlin stays false globally (gradle.properties)
    //     because these plugin modules still apply legacy KGP in their own
    //     build files: file_picker, hidden_volume, mobile_scanner,
    //     package_info_plus, veil_flutter, wakelock_plus (two of them are
    //     third_party submodules we do not patch).
    //   * org.jetbrains.kotlin.android therefore remains on the build
    //     classpath (apply false) for those modules; 2.3.20 is the
    //     Flutter-blessed KGP for Gradle 9.1 (older 2.2.x predates Gradle 9).
    id("com.android.application") version "9.0.1" apply false
    id("com.android.built-in-kotlin") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
