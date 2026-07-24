allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// veil_flutter (third_party submodule — deliberately not patched) pins
// compileSdk 34, but its plugin dependency :mobile_scanner and the transitive
// androidx.camera 1.6.1 AARs publish minCompileSdk=36 metadata, which AGP 9's
// checkAarMetadata enforces for project dependencies as well (AGP 8 let this
// through). Raise that one module's compileSdk from the app side; compiling
// the unchanged sources against the newer SDK is the action the check itself
// recommends. The afterEvaluate is registered here (before the module's own
// build script runs) so it executes ahead of AGP's own finalization hooks.
project(":veil_flutter") {
    afterEvaluate {
        if (pluginManager.hasPlugin("com.android.library")) {
            extensions.configure<com.android.build.gradle.LibraryExtension> {
                compileSdk = 36
            }
        }
    }
}

// file_picker skips applying the legacy Kotlin Android plugin whenever the AGP
// major version is >= 9 and assumes AGP's built-in Kotlin will compile its
// Kotlin sources. It only checks the AGP version, not the
// android.builtInKotlin property, which this app keeps false globally because
// other plugin modules still need legacy KGP (see gradle.properties). Without
// help the module would get neither Kotlin path and :app would fail to find
// FilePickerPlugin. Opt exactly this module into built-in Kotlin; its
// jvmTarget then defaults to the module's own targetCompatibility (17).
findProject(":file_picker")?.run {
    plugins.withId("com.android.library") {
        pluginManager.apply("com.android.built-in-kotlin")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
