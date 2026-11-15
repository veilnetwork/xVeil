package network.veil.xveil

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.file.Path
import java.security.Key
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec

/** Read the pinned FSS 10.3.4 public metadata format without constructing any
 * plugin cipher/SharedPreferences owner. This port has no mutation capability.
 * Missing records need no keys; damaged existing records never become absence.
 */
internal class QuickUnlockPublicReader(
    private val directory: Path,
    private val prefix: String,
    private val unwrapExisting: (ByteArray) -> Key,
) {
    fun read(key: String): String? {
        val namespace = QuickUnlockPersistence.namespace(key, false)
        val dataFile = QuickUnlockPreferenceFile(directory.resolve("$namespace.xml"), "${prefix}_xveil.quick.v1.")
        val data = dataFile.snapshot()
        val encoded = data["${prefix}_$key"] ?: return null
        val configFile = QuickUnlockPreferenceFile(
            directory.resolve("FlutterSecureStorageConfiguration:$namespace.xml"), null,
        )
        val keyFile = QuickUnlockPreferenceFile(
            directory.resolve("FlutterSecureKeyStorage:$namespace.xml"), null, setOf(WRAPPED_KEY),
        )
        val config = configFile.snapshot()
        val keys = keyFile.snapshot()
        check(config["FlutterSecureSAlgorithmKey"] == "RSA_ECB_OAEPwithSHA_256andMGF1Padding")
        check(config["FlutterSecureSAlgorithmStorage"] == "AES_GCM_NoPadding")
        val wrapped = decode(checkNotNull(keys[WRAPPED_KEY]))
        var clear: ByteArray? = null
        try {
            val secret = unwrapExisting(wrapped)
            check(secret.algorithm == "AES")
            val payload = decode(encoded)
            check(payload.size >= 12 + 16)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, payload, 0, 12))
            clear = cipher.doFinal(payload, 12, payload.size - 12)
            // Refuse observable changes during this read; never return an old
            // cached record after a completed removal or configuration change.
            check(dataFile.snapshot() == data && configFile.snapshot() == config && keyFile.snapshot() == keys)
            return Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(clear)).toString()
        } finally {
            wrapped.fill(0)
            clear?.fill(0)
        }
    }

    private fun decode(value: String): ByteArray = Base64.getDecoder().decode(
        value.filterNot { it == '\r' || it == '\n' || it == ' ' || it == '\t' },
    )

    companion object {
        // Exact preference name written by the selected plugin's GCM cipher.
        const val WRAPPED_KEY = "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"
    }
}
