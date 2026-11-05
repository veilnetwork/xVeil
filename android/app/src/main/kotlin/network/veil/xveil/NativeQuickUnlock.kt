package network.veil.xveil

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.NamespacedConfigSource
import com.it_nomads.fluttersecurestorage.ciphers.StorageCipherFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.Executors
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/** Read existing FSS 10.3.4 slots without its process-wide decrypted-key cache.
 * Configuration/writes/deletion remain in the plugin; no storage format changes.
 */
class NativeQuickUnlock(private val activity: Activity, messenger: BinaryMessenger) {
    private class Read(val key: String, val reason: String, val result: MethodChannel.Result) {
        val cancellation = CancellationSignal()
    }
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val gate = QuickUnlockReadGate<Read>()
    private val channel = MethodChannel(messenger, "xveil/quick_unlock")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "read") {
                result.notImplemented()
            } else {
                val key = call.argument<String>("key")
                val reason = call.argument<String>("reason")
                if (key == null || !key.startsWith("xveil.quick.v1.") ||
                    !key.contains(".bio.") || key.length > 4096 ||
                    reason.isNullOrBlank() || reason.length > 256) {
                    result.error("invalid_request", "Invalid quick-unlock request", null)
                } else if (Build.VERSION.SDK_INT < 28) {
                    result.error("unavailable", "Protected biometric reads require Android 9", null)
                } else {
                    val read = Read(key, reason, result)
                    if (!gate.begin(read)) {
                        result.error("busy", "Quick unlock is already pending or closed", null)
                    } else {
                        worker.execute { prepare(read) }
                    }
                }
            }
        }
    }

    private fun prepare(read: Read) {
        try {
            val namespace = "xveil_quick_bio_v1_" + MessageDigest.getInstance("SHA-256")
                .digest(read.key.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }.take(24)
            val config = FlutterSecureStorageConfig(mapOf<String, Any>(
                "storageNamespace" to namespace,
                "keyCipherAlgorithm" to "AES_GCM_NoPadding",
                "storageCipherAlgorithm" to "AES_GCM_NoPadding",
                "enforceBiometrics" to "true",
                "biometricType" to "strongBiometricOnly",
                "resetOnError" to "false",
                "migrateOnAlgorithmChange" to "false",
            ))
            val prefs = activity.getSharedPreferences(config.effectiveDataPrefsName, Activity.MODE_PRIVATE)
            val encoded = prefs.getString(config.sharedPreferencesKeyPrefix + "_" + read.key, null)
            if (encoded == null) {
                main.post { finish(read, null) }
                return
            }
            // Guard before Factory construction: it writes markers if absent.
            // Unlock is strictly read-only, never migration/reset/key generation.
            val source = NamespacedConfigSource(activity, config.effectiveDataPrefsName)
            check(source.getString("FlutterSecureSAlgorithmKey", null) == "AES_GCM_NoPadding")
            check(source.getString("FlutterSecureSAlgorithmStorage", null) == "AES_GCM_NoPadding")
            val keyPrefs = activity.getSharedPreferences(config.effectiveKeyStoragePrefsName, Activity.MODE_PRIVATE)
            check(keyPrefs.contains("KeyStoreIV1"))
            check(keyPrefs.contains("BVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"))
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val alias = activity.packageName + ".FlutterSecureStoragePluginKey" + config.keyAliasSuffix
            val key = ks.getKey(alias, null) as SecretKey
            val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
                .getKeySpec(key, KeyInfo::class.java) as KeyInfo
            check(info.isUserAuthenticationRequired && info.userAuthenticationValidityDurationSeconds <= 0)
            check(info.isInvalidatedByBiometricEnrollment)
            if (Build.VERSION.SDK_INT >= 30) {
                check(info.userAuthenticationType == KeyProperties.AUTH_BIOMETRIC_STRONG)
            }
            val factory = StorageCipherFactory(source, config.prefOptionKeyCipherAlgorithm,
                config.prefOptionStorageCipherAlgorithm, config)
            check(!factory.requiresReEncryption())
            val cipher = checkNotNull(factory.getCurrentKeyCipher(activity).getCipher(activity))
            main.post {
                if (!gate.owns(read)) return@post
                try {
                    val builder = BiometricPrompt.Builder(activity).setTitle(read.reason)
                        .setNegativeButton(activity.getString(android.R.string.cancel), activity.mainExecutor) { _, _ ->
                            if (gate.finish(read)) {
                                read.cancellation.cancel()
                                read.result.success(null)
                            }
                        }
                    if (Build.VERSION.SDK_INT >= 30) {
                        builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                    }
                    builder.build().authenticate(BiometricPrompt.CryptoObject(cipher),
                        read.cancellation, activity.mainExecutor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationError(code: Int, text: CharSequence) {
                                finish(read, null)
                            }
                            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                                if (!gate.owns(read)) return
                                if (result.cryptoObject?.cipher !== cipher) {
                                    fail(read)
                                    return
                                }
                                worker.execute {
                                    var clear: ByteArray? = null
                                    try {
                                        // Fresh storage cipher per request; never retain its unwrapped key.
                                        val storage = factory.getCurrentStorageCipher(activity, cipher)
                                        clear = storage.decrypt(Base64.decode(encoded, Base64.DEFAULT))
                                        val value = clear.toString(Charsets.UTF_8)
                                        main.post { finish(read, value) }
                                    } catch (_: Exception) {
                                        main.post { fail(read) }
                                    } finally {
                                        clear?.fill(0)
                                    }
                                }
                            }
                        })
                } catch (_: Exception) { fail(read) }
            }
        } catch (_: Exception) {
            main.post { fail(read) }
        }
    }

    private fun finish(read: Read, value: String?) {
        if (gate.finish(read)) read.result.success(value)
    }
    private fun fail(read: Read) {
        if (gate.finish(read)) {
            read.result.error("protected_read_failed", "Protected quick-unlock read failed", null)
        }
    }
    fun cancel() {
        gate.cancel()?.let { read ->
            read.cancellation.cancel()
            read.result.success(null)
        }
    }
    fun dispose() {
        gate.close()?.let { read ->
            read.cancellation.cancel()
            read.result.success(null)
        }
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
