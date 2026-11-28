package network.veil.xveil

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.security.KeyStoreException
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.NamespacedConfigSource
import com.it_nomads.fluttersecurestorage.ciphers.StorageCipherFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import javax.crypto.Cipher
import javax.crypto.BadPaddingException
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import java.io.File
import java.util.concurrent.Executors
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/** Read existing FSS 10.3.4 slots without its process-wide decrypted-key cache.
 * The plugin owns encryption; flush confirms its async writes. Raw presence
 * and explicit record removal require no cipher initialization or format change.
 */
class NativeQuickUnlock(private val activity: Activity, messenger: BinaryMessenger) {
    private class Read(val key: String, val reason: String, val result: MethodChannel.Result) {
        val cancellation = CancellationSignal()
    }
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val gate = QuickUnlockReadGate<Read>()
    private val channel = MethodChannel(messenger, "xveil/quick_unlock")
    private val context = activity.applicationContext
    private val preferenceDirectory = File(context.dataDir, "shared_prefs").toPath()
    private val prefix = FlutterSecureStorageConfig(emptyMap<String, Any>()).sharedPreferencesKeyPrefix
    private val persistence = QuickUnlockPersistence { name ->
        context.getSharedPreferences(name, Activity.MODE_PRIVATE).edit().commit()
    }
    private val publicReader = QuickUnlockPublicReader(preferenceDirectory, prefix) { namespace, wrapped ->
        // Only retrieve an existing private key. No plugin/factory constructor:
        // those constructors can generate keys between a preflight and use.
        try {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val alias = context.packageName + ".FlutterSecureStoragePluginKeyOAEP.$namespace"
            val key = ks.getKey(alias, null) as? PrivateKey
                ?: throw QuickUnlockPublicReadFailure(QuickUnlockPublicReadFailure.Reason.KEY)
            val cipher = Cipher.getInstance("RSA/ECB/OAEPPadding", "AndroidKeyStoreBCWorkaround")
            cipher.init(Cipher.UNWRAP_MODE, key,
                OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT))
            cipher.unwrap(wrapped, "AES", Cipher.SECRET_KEY)
        } catch (error: Exception) {
            if (permanentKeyFailure(error)) {
                throw QuickUnlockPublicReadFailure(QuickUnlockPublicReadFailure.Reason.KEY)
            }
            throw error
        }
    }
    private val records = QuickUnlockRecordStore(prefix, publicReader::namespace) { namespace ->
        val backing = QuickUnlockPreferenceFile(preferenceDirectory.resolve("$namespace.xml"), "${prefix}_xveil.quick.v1.")
        backing.contains() // Before framework loading can hide/repair malformed state.
        val preferences = context.getSharedPreferences(namespace, Activity.MODE_PRIVATE)
        object : QuickUnlockRecordPreferences {
            override fun contains(key: String): Boolean {
                return backing.checkedSnapshot(preferences.all).containsKey(key)
            }
            override fun removeAndCommit(key: String): Boolean {
                contains(key) // Never rewrite an unknown map from an empty fallback.
                return preferences.edit().remove(key).commit()
            }
        }
    }
    private val repair = QuickUnlockRecordRepair(preferenceDirectory, prefix, publicReader, records)
    private var closed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method in setOf("flush", "contains", "remove", "readPublic", "publicWriteNamespace", "repairPublic")) {
                val args = call.arguments as? Map<*, *>
                val key = args?.get("key") as? String
                val biometric = args?.get("biometric") as? Boolean
                if (closed || key == null || biometric == null) {
                    result.error("invalid_request", "Invalid quick-unlock record request", null)
                } else {
                    try {
                        QuickUnlockPersistence.namespace(key, biometric)
                        if (call.method in setOf("readPublic", "publicWriteNamespace", "repairPublic")) require(!biometric)
                        // Do not block the UI thread. Accepted commits survive
                        // dispose's executor shutdown and settle their own reply.
                        worker.execute {
                            try {
                                val answer = when (call.method) {
                                    "readPublic" -> publicReader.read(key)
                                    "publicWriteNamespace" -> {
                                        records.contains(key, false) // Check the destination before plugin initialization.
                                        publicReader.namespaceForWrite(key)
                                    }
                                    "repairPublic" -> repair.removeUnreadable(key)
                                    "contains" -> records.contains(key, biometric)
                                    "remove" -> { records.remove(key, biometric); true }
                                    else -> {
                                        persistence.flush(key, biometric, args["publicNamespace"] as? String)
                                        true
                                    }
                                }
                                main.post { result.success(answer) }
                            } catch (error: Exception) {
                                main.post {
                                    result.error(if (error is QuickUnlockRecordFileFailure) "record_store_unreadable"
                                        else if (call.method == "flush") "persistence_failed" else "record_operation_failed",
                                        "Quick-unlock record operation not confirmed",
                                        (error as? QuickUnlockPublicReadFailure)?.reason?.name)
                                }
                            }
                        }
                    } catch (_: Exception) {
                        result.error(if (call.method == "flush") "persistence_failed" else "record_operation_failed",
                            "Quick-unlock record operation not confirmed", null)
                    }
                }
            } else if (call.method != "read") {
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
            val namespace = QuickUnlockPersistence.namespace(read.key, true)
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
                main.post { fail(read, "protected_record_missing") }
                return
            }
            // Guard before Factory construction: it writes markers if absent.
            // Unlock is strictly read-only, never migration/reset/key generation.
            val source = NamespacedConfigSource(activity, config.effectiveDataPrefsName)
            val keyPrefs = activity.getSharedPreferences(config.effectiveKeyStoragePrefsName, Activity.MODE_PRIVATE)
            val wrapping = source.getString("FlutterSecureSAlgorithmKey", null)
            val storage = source.getString("FlutterSecureSAlgorithmStorage", null)
            if (wrapping == null || storage == null ||
                !keyPrefs.contains("KeyStoreIV1") ||
                !keyPrefs.contains("BVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK")) {
                main.post { fail(read, "protected_record_missing") }
                return
            }
            check(wrapping == "AES_GCM_NoPadding" && storage == "AES_GCM_NoPadding")
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val alias = activity.packageName + ".FlutterSecureStoragePluginKey" + config.keyAliasSuffix
            val key = ks.getKey(alias, null) as? SecretKey
            if (key == null) {
                main.post { fail(read, "authentication_protection_changed") }
                return
            }
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
                                read.result.error("authentication_cancelled", "System authentication was cancelled", null)
                            }
                        }
                    if (Build.VERSION.SDK_INT >= 30) {
                        builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                    }
                    builder.build().authenticate(BiometricPrompt.CryptoObject(cipher),
                        read.cancellation, activity.mainExecutor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationError(code: Int, text: CharSequence) {
                                val reason = when (code) {
                                    BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
                                    BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                                    BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT -> "authentication_cancelled"
                                    BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS,
                                    BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL -> "authentication_not_enrolled"
                                    BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
                                    BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> "authentication_locked"
                                    BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT,
                                    BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "unavailable"
                                    else -> "protected_read_failed"
                                }
                                if (gate.finish(read)) {
                                    read.result.error(reason, "System authentication did not complete", null)
                                }
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
                                    } catch (error: Exception) {
                                        main.post { fail(read, protectedReadFailure(error)) }
                                    } finally {
                                        clear?.fill(0)
                                    }
                                }
                            }
                        })
                } catch (_: Exception) { fail(read) }
            }
        } catch (error: Exception) {
            main.post { fail(read, protectedReadFailure(error)) }
        }
    }

    private fun finish(read: Read, value: String?) {
        if (gate.finish(read)) read.result.success(value)
    }
    private fun fail(read: Read, code: String = "protected_read_failed") {
        if (gate.finish(read)) {
            read.result.error(code, "Protected quick-unlock read failed", null)
        }
    }

    private fun keyCauses(error: Throwable): List<Throwable> =
        generateSequence(error) { it.cause }.take(12).toList()

    private fun permanentKeyFailure(error: Throwable): Boolean {
        val causes = keyCauses(error)
        if (Build.VERSION.SDK_INT >= 33) {
            val system = causes.filterIsInstance<KeyStoreException>()
            if (system.any { it.isSystemError || it.isTransientFailure }) return false
            if (system.any {
                    it.numericErrorCode == KeyStoreException.ERROR_KEY_DOES_NOT_EXIST ||
                        it.numericErrorCode == KeyStoreException.ERROR_KEY_CORRUPTED
                }) return true
        }
        return causes.any { it is KeyPermanentlyInvalidatedException || it is BadPaddingException }
    }

    private fun protectedReadFailure(error: Throwable): String {
        val causes = keyCauses(error)
        if (causes.any { it is KeyPermanentlyInvalidatedException }) {
            return "authentication_protection_changed"
        }
        if (Build.VERSION.SDK_INT >= 33) {
            val system = causes.filterIsInstance<KeyStoreException>()
            if (system.any { it.isSystemError || it.isTransientFailure }) return "unavailable"
            if (system.any { it.numericErrorCode == KeyStoreException.ERROR_KEY_DOES_NOT_EXIST }) {
                return "authentication_protection_changed"
            }
        }
        return "protected_read_failed"
    }
    fun cancel() {
        gate.cancel()?.let { read ->
            read.cancellation.cancel()
            read.result.success(null)
        }
    }
    fun dispose() {
        closed = true
        gate.close()?.let { read ->
            read.cancellation.cancel()
            read.result.success(null)
        }
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
