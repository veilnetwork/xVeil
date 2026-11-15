package network.veil.xveil

import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyPairGenerator
import java.security.spec.MGF1ParameterSpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec
import kotlin.system.exitProcess

private fun verifyPublicReader() {
    val root = Files.createTempDirectory("xveil-public-read-")
    val key = "xveil.quick.v1.synthetic"
    val namespace = QuickUnlockPersistence.namespace(key, false)
    val prefix = "fixture"
    val data = root.resolve("$namespace.xml")
    val config = root.resolve("FlutterSecureStorageConfiguration:$namespace.xml")
    val wrappedFile = root.resolve("FlutterSecureKeyStorage:$namespace.xml")
    val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
    val appKey = SecretKeySpec(ByteArray(16) { (it + 1).toByte() }, "AES")
    val params = OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)
    val wrapping = Cipher.getInstance("RSA/ECB/OAEPPadding")
    wrapping.init(Cipher.WRAP_MODE, pair.public, params)
    val wrapped = Base64.getEncoder().encodeToString(wrapping.wrap(appKey))
    val iv = ByteArray(12) { it.toByte() }
    val encrypt = Cipher.getInstance("AES/GCM/NoPadding")
    encrypt.init(Cipher.ENCRYPT_MODE, appKey, GCMParameterSpec(128, iv))
    val value = "synthetic public metadata \u00e9\n"
    val encoded = Base64.getMimeEncoder().encodeToString(iv + encrypt.doFinal(value.toByteArray(Charsets.UTF_8)))
    fun xml(vararg items: Pair<String, String>) = "<map>" + items.joinToString("") {
        "<string name=\"${it.first}\">${it.second}</string>"
    } + "</map>"
    fun write(path: Path, value: String) { Files.write(path, value.toByteArray(Charsets.UTF_8)) }
    val dataXml = xml("${prefix}_$key" to encoded, "${prefix}_${key}sibling" to encoded)
    val configXml = xml("FlutterSecureSAlgorithmKey" to "RSA_ECB_OAEPwithSHA_256andMGF1Padding",
        "FlutterSecureSAlgorithmStorage" to "AES_GCM_NoPadding")
    val keysXml = xml(QuickUnlockPublicReader.WRAPPED_KEY to wrapped)
    fun reset() { write(data, dataXml); write(config, configXml); write(wrappedFile, keysXml) }
    fun snapshot() = Files.list(root).use { stream -> stream.iterator().asSequence().toList().associate {
        it.fileName.toString() to Files.readAllBytes(it).toList()
    } }
    var unwraps = 0
    var beforeUnwrap: (() -> Unit)? = null
    var refuseKey = false
    val reader = QuickUnlockPublicReader(root, prefix) { bytes ->
        unwraps++
        beforeUnwrap?.invoke()
        check(!refuseKey)
        val cipher = Cipher.getInstance("RSA/ECB/OAEPPadding")
        cipher.init(Cipher.UNWRAP_MODE, pair.private, params)
        cipher.unwrap(bytes, "AES", Cipher.SECRET_KEY)
    }
    fun refuses() {
        val before = snapshot()
        var failed = false
        try { reader.read(key) } catch (_: Exception) { failed = true }
        check(failed)
        check(before == snapshot())
    }
    try {
        check(reader.read(key) == null && unwraps == 0 && snapshot().isEmpty())
        reset()
        val original = snapshot()
        repeat(3) { check(reader.read(key) == value) }
        check(unwraps == 3 && original == snapshot())
        write(data, xml("${prefix}_${key}sibling" to encoded))
        Files.delete(config); Files.delete(wrappedFile)
        check(reader.read(key) == null && unwraps == 3)
        check(Files.exists(data) && !Files.exists(config) && !Files.exists(wrappedFile))
        for (marker in listOf("<map />", configXml.replace("AES_GCM_NoPadding", "AES_CBC_PKCS7Padding"), "<map>")) {
            reset(); write(config, marker); val before = unwraps; refuses(); check(unwraps == before)
        }
        reset(); Files.delete(config); refuses()
        reset(); Files.delete(wrappedFile); refuses()
        reset(); write(wrappedFile, "<map />"); refuses()
        reset(); write(wrappedFile, "<map>"); refuses()
        reset(); write(wrappedFile, xml(QuickUnlockPublicReader.WRAPPED_KEY to "%%%")); refuses()
        reset(); write(data, "<map>"); val before = unwraps; refuses(); check(before == unwraps)
        reset(); refuseKey = true; refuses(); refuseKey = false
        reset(); write(data, xml("${prefix}_$key" to Base64.getEncoder().encodeToString(ByteArray(32)))); refuses()
        reset(); val backup = config.resolveSibling(config.fileName.toString() + ".bak")
        write(backup, configXml); refuses(); Files.delete(backup)
        reset(); var failed = false
        beforeUnwrap = { write(data, "<map />") }
        try { reader.read(key) } catch (_: Exception) { failed = true }
        check(failed && Files.readString(data) == "<map />")
        reset(); failed = false
        beforeUnwrap = { write(config, "<map />") }
        try { reader.read(key) } catch (_: Exception) { failed = true }
        check(failed && Files.readString(config) == "<map />")
        beforeUnwrap = null
        reset(); val intact = snapshot(); val seen = unwraps
        for (bad in listOf("foreign", "$key.bio.slot", "xveil.quick.v1.")) {
            failed = false
            try { reader.read(bad) } catch (_: Exception) { failed = true }
            check(failed)
        }
        check(snapshot() == intact && unwraps == seen)
        check(reader.read(key) == value)
    } finally {
        Files.walk(root).use { it.sorted(Comparator.reverseOrder()).forEach(Files::delete) }
    }
}

fun main() {
    try {
        verifyPublicReader()
        println("quick-unlock read-only public record checks passed")
    } catch (_: Throwable) {
        println("quick-unlock read-only public record checks failed")
        exitProcess(1)
    }
}
