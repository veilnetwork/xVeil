package network.veil.xveil

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import kotlin.system.exitProcess

private fun verifyPersistence() {
    val key = "xveil.quick.v1." + "a".repeat(64)
    val protectedKey = "$key.bio.synthetic/+="
    check(QuickUnlockPersistence.namespace(key, false) == "xveil_quick_pattern_v1")
    check(QuickUnlockPersistence.namespace(protectedKey, true) ==
        "xveil_quick_bio_v1_fc56b86e286ddc6b37cfba05")
    check(QuickUnlockPersistence.namespace("$key.bio.other", true) !=
        QuickUnlockPersistence.namespace(protectedKey, true))

    val expected = listOf(
        "FlutterSecureKeyStorage:xveil_quick_pattern_v1",
        "FlutterSecureStorageConfiguration:xveil_quick_pattern_v1",
        "xveil_quick_pattern_v1",
    )
    val committed = mutableListOf<String>()
    QuickUnlockPersistence { committed.add(it); true }.flush(key, false)
    check(committed == expected)

    // A refusal/exception at any dependency must refuse success, while still
    // settling all already accepted namespace writes.
    for (failed in expected.indices) {
        for (throws in listOf(false, true)) {
            committed.clear()
            var refused = false
            try {
                QuickUnlockPersistence {
                    committed.add(it)
                    if (it == expected[failed]) {
                        if (throws) throw IllegalStateException("synthetic refusal")
                        false
                    } else true
                }.flush(key, false)
            } catch (_: IllegalStateException) { refused = true }
            check(refused)
            check(committed == expected)
        }
    }

    for ((bad, biometric) in listOf(
        "foreign.namespace" to false,
        "xveil.quick.v1." to false,
        "$key\u0000other" to false,
        key.repeat(100) to false,
        key to true,
        protectedKey to false,
    )) {
        var refused = false
        try {
            QuickUnlockPersistence { error("invalid request reached disk") }
                .flush(bad, biometric)
        } catch (_: IllegalArgumentException) { refused = true }
        check(refused)
    }

    // Match the native bridge's actual executor ownership: shutdown accepts no
    // new tasks but must let the accepted disk commit finish before its reply.
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val worker = Executors.newSingleThreadExecutor()
    try {
        val accepted = worker.submit {
            QuickUnlockPersistence {
                if (it == expected.last()) {
                    entered.countDown()
                    release.await()
                }
                true
            }.flush(key, false)
        }
        entered.await()
        worker.shutdown()
        check(!accepted.isDone)
        release.countDown()
        accepted.get()
    } finally {
        release.countDown()
        worker.shutdownNow()
    }
}

fun main() {
    try {
        verifyPersistence()
        println("quick-unlock persistence checks passed")
    } catch (_: Throwable) {
        println("quick-unlock persistence checks failed")
        exitProcess(1)
    }
}
