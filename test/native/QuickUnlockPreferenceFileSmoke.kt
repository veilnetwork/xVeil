package network.veil.xveil

import java.nio.file.Files
import kotlin.system.exitProcess

private fun verifyPreferenceFiles() {
    val root = Files.createTempDirectory("xveil-record-file-")
    val file = root.resolve("data.xml")
    val backing = QuickUnlockPreferenceFile(file, "fixture_")
    val empty = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?><map />"
    val complete = "<map><string name=\"fixture_key\">ciphertext&#10;more</string>" +
        "<string name=\"fixture_sibling\">ciphertext&amp;value</string></map>"
    fun write(text: String) { Files.write(file, text.toByteArray()) }
    fun refuses() {
        val before = if (Files.isRegularFile(file)) Files.readAllBytes(file) else null
        var refused = false
        try { backing.contains("fixture_key") } catch (_: QuickUnlockRecordFileFailure) { refused = true }
        check(refused)
        if (before != null) check(Files.readAllBytes(file).contentEquals(before))
    }
    try {
        check(!backing.contains("fixture_key"))
        check(!Files.exists(file))
        write(empty)
        check(!backing.contains("fixture_key"))
        write(complete)
        check(backing.contains("fixture_key"))
        check(!backing.contains("missing"))
        val expected = mapOf("fixture_key" to "ciphertext\nmore", "fixture_sibling" to "ciphertext&value")
        check(backing.snapshot() == expected)
        check(backing.checkedSnapshot(expected) == expected)
        for (stale in listOf(emptyMap<String, String>(), expected - "fixture_sibling",
            expected + ("fixture_sibling" to "older ciphertext"), expected + ("other" to "stale"))) {
            var refused = false
            try { backing.checkedSnapshot(stale) } catch (_: QuickUnlockRecordFileFailure) { refused = true }
            check(refused)
            check(Files.readAllBytes(file).contentEquals(complete.toByteArray()))
        }
        write(complete.replace("<map>", "<map><string name=\"__androidx_security_crypto_encrypted_prefs_key_keyset__\">bookkeeping</string>"))
        check(backing.contains("fixture_key"))
        write(complete)
        check(Files.readAllBytes(file).contentEquals(complete.toByteArray()))
        for (bad in listOf(
            "", "<map>", complete.removeSuffix("</map>"),
            "<list />", "<map version=\"2\" />", "<map><string>no name</string></map>",
            "<map><string name=\"fixture_key\"><string>nested</string></string></map>",
            "<map><string name=\"fixture_key\">one</string><string name=\"fixture_key\">two</string></map>",
            "<map><string name=\"unrecognized_opaque_record\">opaque</string></map>",
            "<!DOCTYPE map [<!ENTITY fixture 'value'>]><map><string name=\"fixture_key\">&fixture;</string></map>",
        )) { write(bad); refuses() }
        // Android's serializer may indent the closing tag after FSS's trailing
        // Base64 newline. The live cache then lacks those four on-disk spaces.
        val base64 = "Y2lwaGVydGV4dA==\n"
        val padded = "<map><string name=\"fixture_key\">${base64}    </string></map>"
        write(padded)
        val live = mapOf("fixture_key" to base64)
        check(backing.checkedSnapshot(live)["fixture_key"] == base64 + "    ")
        check(Files.readAllBytes(file).contentEquals(padded.toByteArray()))
        for (other in listOf("Y2lwaGVydGV4dQ==\n", base64 + "\u00a0", "not base64\n")) {
            var refused = false
            try { backing.checkedSnapshot(mapOf("fixture_key" to other)) }
            catch (_: QuickUnlockRecordFileFailure) { refused = true }
            check(refused)
        }
        write("<map><string name=\"fixture_key\">invalid-value    </string></map>")
        var invalidRefused = false
        try { backing.checkedSnapshot(mapOf("fixture_key" to "invalid-value")) }
        catch (_: QuickUnlockRecordFileFailure) { invalidRefused = true }
        check(invalidRefused)
        val bookkeeping = "__androidx_security_crypto_encrypted_prefs_key_keyset__"
        write("<map><string name=\"$bookkeeping\">$base64    </string></map>")
        var bookkeepingRefused = false
        try { backing.checkedSnapshot(mapOf(bookkeeping to base64)) }
        catch (_: QuickUnlockRecordFileFailure) { bookkeepingRefused = true }
        check(bookkeepingRefused)
        write(complete)
        val backup = root.resolve("data.xml.bak")
        Files.write(backup, complete.toByteArray())
        refuses()
        check(Files.readAllBytes(backup).contentEquals(complete.toByteArray()))
        Files.delete(backup)
        Files.delete(file)
        val target = root.resolve("outside.xml")
        Files.write(target, complete.toByteArray())
        Files.createSymbolicLink(file, target)
        refuses()
        check(Files.readAllBytes(target).contentEquals(complete.toByteArray()))
        Files.delete(file)
        Files.delete(target)
        Files.createDirectory(file)
        refuses()
    } finally {
        Files.walk(root).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach { Files.delete(it) } }
    }
}

fun main() {
    try {
        verifyPreferenceFiles()
        println("quick-unlock backing file checks passed")
    } catch (_: Throwable) {
        println("quick-unlock backing file checks failed")
        exitProcess(1)
    }
}
