package network.veil.xveil

/** Only record-presence and durable single-key removal, without decrypting,
 * migrating or generating keys. No broad clear/read/write capability.
 */
internal interface QuickUnlockRecordPreferences {
    fun contains(key: String): Boolean
    fun removeAndCommit(key: String): Boolean
}

internal class QuickUnlockRecordStore(
    private val prefix: String,
    private val open: (String) -> QuickUnlockRecordPreferences,
) {
    init { require(prefix.isNotEmpty() && prefix.length <= 256 && !prefix.contains('\u0000')) }

    private fun record(key: String, biometric: Boolean): Pair<QuickUnlockRecordPreferences, String> {
        val namespace = QuickUnlockPersistence.namespace(key, biometric)
        return open(namespace) to "${prefix}_$key"
    }

    fun contains(key: String, biometric: Boolean): Boolean {
        val (preferences, prefixed) = record(key, biometric)
        return preferences.contains(prefixed)
    }

    fun remove(key: String, biometric: Boolean) {
        val (preferences, prefixed) = record(key, biometric)
        check(preferences.removeAndCommit(prefixed)) { "Saved-entry removal not persisted" }
        check(!preferences.contains(prefixed)) { "Saved-entry record remains" }
    }
}
