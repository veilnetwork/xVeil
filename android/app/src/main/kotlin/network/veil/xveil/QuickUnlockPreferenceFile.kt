package network.veil.xveil

import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.attribute.BasicFileAttributes
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory

internal class QuickUnlockRecordFileFailure : Exception("Saved-entry backing store unavailable")

/** SharedPreferences can silently substitute an empty map for unreadable XML.
 * Inspect the fixed private backing file without repairing/replacing it before
 * using that map as an absence witness or a source for a destructive commit.
 */
internal class QuickUnlockPreferenceFile(
    private val path: Path,
    private val recordPrefix: String?,
    private val extraNames: Set<String> = emptySet(),
) {
    private val backup = path.resolveSibling(path.fileName.toString() + ".bak")

    private fun attributes(file: Path): BasicFileAttributes? = try {
        Files.readAttributes(file, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
    } catch (_: NoSuchFileException) { null }

    private fun noBackup() { check(attributes(backup) == null) }

    fun contains(wanted: String? = null): Boolean = snapshot().containsKey(wanted)

    /** Compare the entire framework cache, including siblings and bookkeeping.
     * A previous failed load may have cached an empty map even after the file
     * becomes readable; editing that cache would erase unrelated records.
     */
    fun checkedSnapshot(cached: Map<String, *>): Map<String, String> {
        val before = snapshot()
        if (cached.values.any { it !is String } || before != cached || before != snapshot()) {
            throw QuickUnlockRecordFileFailure()
        }
        return before
    }

    fun snapshot(): Map<String, String> = try {
        noBackup()
        val before = attributes(path)
        if (before == null) {
            check(attributes(path) == null)
            noBackup()
            emptyMap()
        } else {
            check(before.isRegularFile && before.fileKey() != null)
            check(before.size() in 1..(16L * 1024 * 1024))
            val values = LinkedHashMap<String, String>()
            Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS).use { input ->
                val parser = XmlPullParserFactory.newInstance().newPullParser()
                parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
                if (parser.getFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL)) {
                    parser.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
                }
                check(!parser.getFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL))
                parser.setInput(input, null)
                var root = false
                var closed = false
                var name: String? = null
                val value = StringBuilder()
                while (true) {
                    when (parser.nextToken()) {
                        XmlPullParser.START_TAG -> {
                            check(!closed && parser.depth <= 2)
                            if (parser.depth == 1) {
                                check(!root && parser.name == "map" && parser.attributeCount == 0)
                                root = true
                            } else if (parser.depth == 2) {
                                // This pinned FSS data layout stores strings
                                // only; config/key files are separate stores.
                                check(root && parser.name == "string" && parser.attributeCount == 1)
                                name = checkNotNull(parser.getAttributeValue(null, "name"))
                                check(values.size < 65536 && !values.containsKey(name))
                                // FSS creates Tink bookkeeping even on its
                                // default raw-key path. Opaque credential names
                                // from an active encrypted-key layout refuse.
                                check((recordPrefix != null && name.startsWith(recordPrefix)) || name in extraNames || name in setOf(
                                    "__androidx_security_crypto_encrypted_prefs_key_keyset__",
                                    "__androidx_security_crypto_encrypted_prefs_value_keyset__",
                                    "FlutterSecureSAlgorithmKey", "FlutterSecureSAlgorithmStorage",
                                ))
                                value.setLength(0)
                            }
                        }
                        XmlPullParser.END_TAG -> if (parser.depth == 1) closed = true else {
                            values[checkNotNull(name)] = value.toString()
                            name = null
                        }
                        XmlPullParser.TEXT, XmlPullParser.CDSECT, XmlPullParser.IGNORABLE_WHITESPACE -> {
                            if (name == null) check(parser.text.isBlank()) else value.append(parser.text)
                        }
                        XmlPullParser.DOCDECL -> error("unsupported declaration")
                        XmlPullParser.ENTITY_REF -> {
                            check(name != null)
                            check(parser.name in setOf("lt", "gt", "amp", "apos", "quot") ||
                                parser.name.matches(Regex("#(?:[0-9]+|x[0-9a-fA-F]+)")))
                            value.append(checkNotNull(parser.text))
                        }
                        XmlPullParser.END_DOCUMENT -> { check(root && closed); break }
                    }
                }
            }
            val after = checkNotNull(attributes(path))
            check(after.isRegularFile && before.fileKey() == after.fileKey() &&
                before.size() == after.size() && before.lastModifiedTime() == after.lastModifiedTime())
            noBackup()
            values
        }
    } catch (_: Exception) { throw QuickUnlockRecordFileFailure() }
}
