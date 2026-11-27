package network.veil.xveil

import java.nio.file.Files
import java.nio.file.Path

/** Explicit replacement of a legacy entry whose wrapping key cannot be used.
 * The old metadata cannot tell us its protected slot. Recover the slot
 * addresses from private preferences, without opening the protected values.
 */
internal class QuickUnlockLegacyRepair(
    private val directory: Path,
    private val prefix: String,
    private val reader: QuickUnlockPublicReader,
    private val records: QuickUnlockRecordStore,
) {
    fun removeUnreadable(key: String): Boolean {
        val legacy = QuickUnlockPersistence.namespace(key, false)
        if (reader.namespace(key) != legacy) return false
        try {
            reader.read(key)
            return false
        } catch (error: QuickUnlockPublicReadFailure) {
            if (error.reason != QuickUnlockPublicReadFailure.Reason.KEY) throw error
        }
        // Keep the original entry until every matching credential is gone.
        // A partial removal remains retryable and never leaves an untracked
        // biometric password behind the unreadable legacy record.
        for (slot in protectedKeys(key)) records.remove(slot, true)
        check(protectedKeys(key).isEmpty())
        check(reader.namespace(key) == legacy)
        records.remove(key, false)
        check(!records.contains(key, false))
        return true
    }

    private fun protectedKeys(key: String): Set<String> {
        val requested = "${prefix}_$key.bio."
        val slots = mutableSetOf<String>()
        val visited = mutableSetOf<String>()
        Files.newDirectoryStream(directory, "xveil_quick_bio_v1_*").use { files ->
            for (path in files) {
                val name = path.fileName.toString()
                val namespace = bioFile.matchEntire(name)?.groupValues?.get(1) ?: continue
                if (!visited.add(namespace)) continue
                check(visited.size <= 16_384)
                val data = QuickUnlockPreferenceFile(directory.resolve("$namespace.xml"), "${prefix}_xveil.quick.v1.")
                for (entry in data.snapshot().keys) {
                    if (!entry.startsWith(requested)) continue
                    val slot = entry.removePrefix("${prefix}_")
                    check(QuickUnlockPersistence.namespace(slot, true) == namespace)
                    check(slots.add(slot))
                }
            }
        }
        return slots
    }

    private companion object {
        val bioFile = Regex("(xveil_quick_bio_v1_[0-9a-f]{24})\\.xml(?:\\.bak)?")
    }
}
