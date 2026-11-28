package network.veil.xveil

import java.security.MessageDigest
import java.util.UUID

/** Flush only the pinned FSS namespaces used by quick unlock. The supplied
 * commit must be synchronous and must propagate its persistence result.
 * No credential values, aliases or filesystem paths cross this port.
 */
internal class QuickUnlockPersistence(private val commit: (String) -> Boolean) {
    fun flush(key: String, biometric: Boolean, publicNamespace: String? = null) {
        val original = namespace(key, biometric)
        require(publicNamespace == null ||
            (!biometric && (publicNamespace == original || isScopedPublicNamespace(key, publicNamespace))))
        val namespace = publicNamespace ?: original
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
        fun freshPublicNamespace(key: String): String {
            namespace(key, false) // Validate the logical address before deriving a namespace.
            return "xveil_quick_pattern_v2_" + digest(key)
        }

        fun rotatedPublicPrefix(key: String): String {
            namespace(key, false)
            return "xveil_quick_pattern_v3_${digest(key)}_"
        }

        fun newPublicNamespace(key: String): String =
            rotatedPublicPrefix(key) + UUID.randomUUID().toString().replace("-", "")

        fun isScopedPublicNamespace(key: String, name: String): Boolean =
            name == freshPublicNamespace(key) ||
                name.startsWith(rotatedPublicPrefix(key)) &&
                name.removePrefix(rotatedPublicPrefix(key)).matches(Regex("[0-9a-f]{32}"))

        fun namespace(key: String, biometric: Boolean): String {
            require(key.startsWith("xveil.quick.v1.") &&
                key.length > "xveil.quick.v1.".length && key.length <= 4096 &&
                !key.contains('\u0000') && key.contains(".bio.") == biometric) {
                "Invalid quick-unlock persistence request"
            }
            if (!biometric) return "xveil_quick_pattern_v1"
            return "xveil_quick_bio_v1_" + digest(key)
        }

        private fun digest(key: String): String =
            MessageDigest.getInstance("SHA-256")
                .digest(key.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }.take(24)
    }
}
