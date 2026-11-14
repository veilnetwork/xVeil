package network.veil.xveil

import java.security.MessageDigest

/** Flush only the pinned FSS namespaces used by quick unlock. The supplied
 * commit must be synchronous and must propagate its persistence result.
 * No credential values, aliases or filesystem paths cross this port.
 */
internal class QuickUnlockPersistence(private val commit: (String) -> Boolean) {
    fun flush(key: String, biometric: Boolean) {
        val namespace = namespace(key, biometric)
        var confirmed = true
        // Wrapped keys/config are dependencies of the encrypted record. The
        // final empty editor also waits for earlier apply() work on that store.
        for (name in listOf(
            "FlutterSecureKeyStorage:$namespace",
            "FlutterSecureStorageConfiguration:$namespace",
            namespace,
        )) {
            try {
                if (!commit(name)) confirmed = false
            } catch (_: Exception) {
                confirmed = false
            }
        }
        check(confirmed) { "Quick-unlock persistence not confirmed" }
    }

    companion object {
        fun namespace(key: String, biometric: Boolean): String {
            require(key.startsWith("xveil.quick.v1.") &&
                key.length > "xveil.quick.v1.".length && key.length <= 4096 &&
                !key.contains('\u0000') && key.contains(".bio.") == biometric) {
                "Invalid quick-unlock persistence request"
            }
            if (!biometric) return "xveil_quick_pattern_v1"
            return "xveil_quick_bio_v1_" + MessageDigest.getInstance("SHA-256")
                .digest(key.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }.take(24)
        }
    }
}
