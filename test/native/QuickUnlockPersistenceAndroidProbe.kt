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
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.plugin.common.FlutterException
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.nio.ByteBuffer
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.ExecutionException
import org.json.JSONObject
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/** Standalone debuggable QA Activity, excluded from the production source set.
 * Uses actual Android Keystore/FSS with a synthetic credential.
 * The driver SIGKILLs the foreground process after each acknowledged phase.
 */
class QuickUnlockPersistenceAndroidProbe : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var missingKeyVerified = false

    /** Only transports StandardMethodCodec bytes to the real registered native
     * handler. It supplies no method results and replaces no Android/FSS port.
     */
    private class PortMessenger(private val activity: Activity) : BinaryMessenger {
        private var handler: BinaryMessenger.BinaryMessageHandler? = null
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            check(channel == "xveil/quick_unlock")
            this.handler = handler
        }
        override fun send(channel: String, message: ByteBuffer?) { error("unexpected outgoing message") }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            error("unexpected outgoing message")
        }
        fun invoke(method: String, arguments: Map<String, Any>): Any? {
            val reply = CompletableFuture<Any?>()
            activity.runOnUiThread {
                try {
                    val encoded = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments))
                    encoded.rewind()
                    checkNotNull(handler).onMessage(encoded) { bytes ->
                        try {
                            checkNotNull(bytes).rewind()
                            reply.complete(StandardMethodCodec.INSTANCE.decodeEnvelope(bytes))
                        } catch (error: Exception) { reply.completeExceptionally(error) }
                    }
                } catch (error: Exception) { reply.completeExceptionally(error) }
            }
            return reply.get(10, TimeUnit.SECONDS)
        }
    }

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
        if (phase !in setOf("write", "present", "delete", "absent",
                "invalidate", "raw_present", "raw_delete", "raw_absent",
                "raw_contains_refused", "raw_remove_refused", "raw_stale_remove_refused") ||
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
                if (phase == "invalidate" || phase!!.startsWith("raw_")) {
                    val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                    val alias = packageName +
                        (if (biometric) ".FlutterSecureStoragePluginKey" else ".FlutterSecureStoragePluginKeyOAEP") +
                        config.keyAliasSuffix
                    if (phase == "invalidate") {
                        check(keystore.containsAlias(alias))
                        keystore.deleteEntry(alias) // This QA application's synthetic key only.
                    } else {
                        check(!keystore.containsAlias(alias))
                        if (phase == "raw_stale_remove_refused") {
                            // Model a framework cache loaded empty during an
                            // earlier failure, followed by a repaired disk file.
                            // The selected absent key differs from this sibling.
                            val file = File(dataDir, "shared_prefs/${config.effectiveDataPrefsName}.xml")
                            val original = file.readBytes()
                            check(getSharedPreferences(config.effectiveDataPrefsName, MODE_PRIVATE)
                                .edit().clear().commit())
                            file.writeBytes(original)
                        }
                        val messenger = PortMessenger(this)
                        val registered = CompletableFuture<NativeQuickUnlock>()
                        runOnUiThread {
                            try { registered.complete(NativeQuickUnlock(this, messenger)) }
                            catch (error: Exception) { registered.completeExceptionally(error) }
                        }
                        val owner = registered.get(10, TimeUnit.SECONDS)
                        try {
                            val selected = if (phase == "raw_stale_remove_refused")
                                "xveil.quick.v1." + "e".repeat(64) else key
                            val arguments = mapOf<String, Any>("key" to selected, "biometric" to biometric)
                            val method = if (phase == "raw_delete" || phase.contains("remove_refused")) "remove" else "contains"
                            if (phase.endsWith("_refused")) {
                                val file = File(dataDir, "shared_prefs/${config.effectiveDataPrefsName}.xml")
                                val before = file.readBytes()
                                var refused = false
                                try { messenger.invoke(method, arguments) }
                                catch (error: ExecutionException) {
                                    check((error.cause as? FlutterException)?.code == "record_store_unreadable")
                                    refused = true
                                }
                                check(refused && before.isNotEmpty() && file.readBytes().contentEquals(before))
                            } else {
                                val reply = messenger.invoke(method, arguments)
                                check(reply == (phase != "raw_absent"))
                            }
                        } finally {
                            val disposed = CompletableFuture<Void>()
                            runOnUiThread { owner.dispose(); disposed.complete(null) }
                            disposed.get(10, TimeUnit.SECONDS)
                        }
                    }
                    check(!keystore.containsAlias(alias)) // No hidden regeneration/authentication path.
                    missingKeyVerified = true
                    report(phase, request, true, biometric)
                    return@execute
                }
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
            .put("missing_key_verified", missingKeyVerified)
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
