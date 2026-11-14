package network.veil.xveil

import kotlin.system.exitProcess

private class RecordPreferences : QuickUnlockRecordPreferences {
    val memory = mutableSetOf<String>()
    val disk = mutableSetOf<String>()
    val removed = mutableListOf<String>()
    var commitResult = true
    var lying = false
    var refuseInspection = false
    override fun contains(key: String): Boolean {
        check(!refuseInspection)
        return memory.contains(key)
    }
    override fun removeAndCommit(key: String): Boolean {
        removed.add(key)
        if (!lying) memory.remove(key)
        if (commitResult) { disk.clear(); disk.addAll(memory) }
        return commitResult
    }
}

private fun verifyRecords() {
    val key = "xveil.quick.v1." + "a".repeat(64)
    val protected = "$key.bio.synthetic"
    val prefix = "fixture"
    val plain = RecordPreferences()
    val biometric = RecordPreferences()
    var opens = 0
    val records = QuickUnlockRecordStore(prefix) { namespace ->
        opens++
        when (namespace) {
            QuickUnlockPersistence.namespace(key, false) -> plain
            QuickUnlockPersistence.namespace(protected, true) -> biometric
            else -> error("unexpected namespace")
        }
    }
    check(!records.contains(key, false))
    check(plain.removed.isEmpty() && plain.disk.isEmpty())
    plain.memory.addAll(listOf("${prefix}_$key", "${prefix}_${key}sibling"))
    plain.disk.addAll(plain.memory)
    biometric.memory.add("${prefix}_$protected")
    biometric.disk.addAll(biometric.memory)
    check(records.contains(key, false) && records.contains(protected, true))
    records.remove(key, false)
    check(plain.memory == setOf("${prefix}_${key}sibling"))
    check(plain.disk == plain.memory)
    check(records.contains(protected, true))
    check(biometric.removed.isEmpty())

    biometric.commitResult = false
    var refused = false
    try { records.remove(protected, true) } catch (_: IllegalStateException) { refused = true }
    check(refused)
    check(!biometric.memory.contains("${prefix}_$protected"))
    check(biometric.disk.contains("${prefix}_$protected"))
    biometric.commitResult = true
    records.remove(protected, true)
    check(biometric.disk.isEmpty())

    biometric.memory.add("${prefix}_$protected")
    biometric.lying = true
    refused = false
    try { records.remove(protected, true) } catch (_: IllegalStateException) { refused = true }
    check(refused && biometric.memory.contains("${prefix}_$protected"))
    biometric.refuseInspection = true
    refused = false
    try { records.contains(protected, true) } catch (_: IllegalStateException) { refused = true }
    check(refused)

    val before = opens
    for ((bad, isBiometric) in listOf("foreign" to false, key to true, protected to false)) {
        var invalid = false
        try { records.contains(bad, isBiometric) } catch (_: IllegalArgumentException) { invalid = true }
        check(invalid)
        invalid = false
        try { records.remove(bad, isBiometric) } catch (_: IllegalArgumentException) { invalid = true }
        check(invalid)
    }
    check(opens == before)
}

fun main() {
    try {
        verifyRecords()
        println("quick-unlock raw record checks passed")
    } catch (_: Throwable) {
        println("quick-unlock raw record checks failed")
        exitProcess(1)
    }
}
