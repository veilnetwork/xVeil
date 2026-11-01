plugins { id("com.android.application") }
android {
 namespace = "com.veil.veil_flutter"
 compileSdk = 36
 defaultConfig { applicationId = "network.veil.callscreenprobe"; minSdk = 26; targetSdk = 36; versionCode = 1; versionName = "1" }
 compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies { implementation("androidx.core:core:1.17.0") }
