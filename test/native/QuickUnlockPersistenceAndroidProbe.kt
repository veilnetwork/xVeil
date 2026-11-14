package network.veil.xveil

import android.app.Activity
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.Build
import android.os.Process
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.view.WindowManager
import android.widget.TextView
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.util.concurrent.Executors
import org.json.JSONObject
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/** Standalone debuggable QA Activity, excluded from the production source set.
 * Uses actual Android Keystore/FSS with a synthetic credential.
 * The driver SIGKILLs the foreground process after each acknowledged phase.
 */
class QuickUnlockPersistenceAndroidProbe : Activity() {
    private val worker = Executors.newSingleThreadExecutor()

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        if (packageName != "network.veil.quickpersistenceprobe" ||
            applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            finish()
            return
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(TextView(this).apply { text = "xVeil persistence QA" })
        val phase = intent.getStringExtra("phase")
        val request = intent.getStringExtra("request")
        val biometric = intent.getBooleanExtra("biometric", false)
        if (phase !in setOf("write", "present", "delete", "absent") ||
            request == null || !request.matches(Regex("[a-z0-9]{1,24}"))) {
            finish()
            return
        }
        worker.execute {
            try {
                val key = "xveil.quick.v1." + "d".repeat(64) +
                    if (biometric) ".bio.synthetic" else ""
                val storage = FlutterSecureStorage(applicationContext)
                val config = FlutterSecureStorageConfig(mapOf<String, Any>(
                    "storageNamespace" to QuickUnlockPersistence.namespace(key, biometric),
                    "resetOnError" to "false",
                    "migrateOnAlgorithmChange" to "true",
                ) + if (biometric) mapOf<String, Any>(
                    "keyCipherAlgorithm" to "AES_GCM_NoPadding",
                    "storageCipherAlgorithm" to "AES_GCM_NoPadding",
                    "enforceBiometrics" to "true",
                    "biometricType" to "strongBiometricOnly",
                ) else emptyMap())
                storage.initialize(config, object : SecurePreferencesCallback<Void> {
                    override fun onSuccess(unused: Void?) {
                        try {
                            if (biometric) {
                                check(Build.VERSION.SDK_INT >= 30)
                                val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                                val alias = packageName + ".FlutterSecureStoragePluginKey" + config.keyAliasSuffix
                                val keyHandle = keystore.getKey(alias, null) as SecretKey
                                val info = SecretKeyFactory.getInstance(keyHandle.algorithm, "AndroidKeyStore")
                                    .getKeySpec(keyHandle, KeyInfo::class.java) as KeyInfo
                                check(info.isUserAuthenticationRequired)
                                check(info.userAuthenticationValidityDurationSeconds <= 0)
                                check(info.isInvalidatedByBiometricEnrollment)
                                check(info.userAuthenticationType == KeyProperties.AUTH_BIOMETRIC_STRONG)
                            }
                            val prefixed = storage.addPrefixToKey(key)
                            val value = "synthetic persistence check"
                            val persistence = QuickUnlockPersistence { name ->
                                applicationContext.getSharedPreferences(name, MODE_PRIVATE)
                                    .edit().commit()
                            }
                            when (phase) {
                                "write" -> {
                                    storage.write(prefixed, value)
                                    persistence.flush(key, biometric)
                                    check(storage.read(prefixed) == value)
                                }
                                "present" -> check(storage.read(prefixed) == value)
                                "delete" -> {
                                    storage.delete(prefixed)
                                    persistence.flush(key, biometric)
                                    check(!storage.containsKey(prefixed))
                                }
                                "absent" -> {
                                    check(!storage.containsKey(prefixed))
                                    check(storage.read(prefixed) == null)
                                }
                            }
                            report(phase!!, request, true, biometric)
                        } catch (_: Exception) { report(phase!!, request, false, biometric) }
                    }
                    override fun onError(error: Exception) {
                        report(phase!!, request, false, biometric)
                    }
                })
            } catch (_: Exception) { report(phase!!, request, false, biometric) }
        }
    }

    private fun report(phase: String, request: String, passed: Boolean, biometric: Boolean) {
        val result = JSONObject()
            .put("schema", "xveil-android-persistence-qa/1")
            .put("phase", phase).put("request", request)
            .put("passed", passed).put("pid", Process.myPid())
            .put("biometric", biometric)
        // This status file is separate from the preference stores; syncing it
        // cannot turn apply() into a preference-persistence receipt.
        FileOutputStream(File(filesDir, "persistence-qa-result.json")).use {
            it.write(result.toString().toByteArray(Charsets.UTF_8))
            it.flush()
            it.fd.sync()
        }
        // Keep the Activity foreground: no cooperative onStop/finish may flush
        // pending preference writes before the driver kills this process.
    }
}
