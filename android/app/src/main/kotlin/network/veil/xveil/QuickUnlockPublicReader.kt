package network.veil.xveil

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.file.Path
import java.security.Key
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec

internal class QuickUnlockPublicReadFailure(val reason: Reason) : Exception() {
    enum class Reason { FORMAT, WRAPPED, KEY, PAYLOAD, CHANGED }
}

/** Read the pinned FSS 10.3.4 public metadata format without constructing any
 * plugin cipher/SharedPreferences owner. This port has no mutation capability.
 * Missing records need no keys; damaged existing records never become absence.
 */
internal class QuickUnlockPublicReader(
    private val directory: Path,
    private val prefix: String,
    private val unwrapExisting: (String, ByteArray) -> Key,
) {
    private fun data(namespace: String) =
        QuickUnlockPreferenceFile(directory.resolve("$namespace.xml"), "${prefix}_xveil.quick.v1.")

    fun namespace(key: String): String {
        val legacy = QuickUnlockPersistence.namespace(key, false)
        val fresh = QuickUnlockPersistence.freshPublicNamespace(key)
        val record = "${prefix}_$key"
        val oldEntry = data(legacy).contains(record)
        check(!oldEntry || !data(fresh).contains(record)) { "Conflicting saved-entry records" }
        return if (oldEntry) legacy else fresh
    }

    fun read(key: String): String? {
        val namespace = namespace(key)
        val dataFile = data(namespace)
        val data = dataFile.snapshot()
        val encoded = data["${prefix}_$key"] ?: return null
        val configFile = QuickUnlockPreferenceFile(
            directory.resolve("FlutterSecureStorageConfiguration:$namespace.xml"), null,
            booleanNames = setOf("ENCRYPTED_PREFERENCES_MIGRATED"),
        )
        val keyFile = QuickUnlockPreferenceFile(
            directory.resolve("FlutterSecureKeyStorage:$namespace.xml"), null,
            setOf(WRAPPED_KEY, LEGACY_WRAPPED_KEY),
        )
        val config = configFile.snapshot()
        val keys = keyFile.snapshot()
        val keyAlgorithm = "FlutterSecureSAlgorithmKey"
        val storageAlgorithm = "FlutterSecureSAlgorithmStorage"
        // The pinned writer can open records already using its current cipher
        // before its separate algorithm markers are present on disk. Older
        // layouts may also still have the markers in the data file. Require
        // compatible hints and prove the format with the GCM authentication tag.
        val hints = if (keyAlgorithm in config && storageAlgorithm in config) config else data
        if (listOf(config, hints).any {
            (it[keyAlgorithm] ?: RSA_OAEP) != RSA_OAEP ||
                (it[storageAlgorithm] ?: AES_GCM) != AES_GCM
        }) {
            throw QuickUnlockPublicReadFailure(QuickUnlockPublicReadFailure.Reason.FORMAT)
        }
        val wrapped = try {
            decode(checkNotNull(keys[WRAPPED_KEY] ?: keys[LEGACY_WRAPPED_KEY]))
        } catch (_: IllegalArgumentException) {
            throw QuickUnlockPublicReadFailure(QuickUnlockPublicReadFailure.Reason.WRAPPED)
        } catch (_: IllegalStateException) {
            throw QuickUnlockPublicReadFailure(QuickUnlockPublicReadFailure.Reason.WRAPPED)
        }
        var clear: ByteArray? = null
        try {
            val secret = try {
                unwrapExisting(namespace, wrapped).also { check(it.algorithm == "AES") }
            } catch (_: Exception) {
                throw QuickUnlockPublicReadFailure(QuickUnlockPublicReadFailure.Reason.KEY)
            }
            val value = try {
                val payload = decode(encoded)
                check(payload.size >= 12 + 16)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, payload, 0, 12))
                val plaintext = cipher.doFinal(payload, 12, payload.size - 12)
                clear = plaintext
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(plaintext)).toString()
            } catch (_: Exception) {
                throw QuickUnlockPublicReadFailure(QuickUnlockPublicReadFailure.Reason.PAYLOAD)
            }
            // Refuse observable changes during this read; never return an old
            // cached record after a completed removal or configuration change.
            if (dataFile.snapshot() != data || configFile.snapshot() != config ||
                keyFile.snapshot() != keys || namespace(key) != namespace) {
                throw QuickUnlockPublicReadFailure(QuickUnlockPublicReadFailure.Reason.CHANGED)
            }
            return value
        } finally {
            wrapped.fill(0)
            clear?.fill(0)
        }
    }

    private fun decode(value: String): ByteArray = Base64.getDecoder().decode(
        value.filterNot { it == '\r' || it == '\n' || it == ' ' || it == '\t' },
    )

    companion object {
        private const val RSA_OAEP = "RSA_ECB_OAEPwithSHA_256andMGF1Padding"
        private const val AES_GCM = "AES_GCM_NoPadding"
        // Exact preference name written by the selected plugin's GCM cipher.
        const val WRAPPED_KEY = "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"
        const val LEGACY_WRAPPED_KEY = "VGhpcyBpcyB0aGUga2V5IGZvcihBIHNlY3XyZZBzdG9yYWdlIEFFUyBLZXkK"
    }
}
