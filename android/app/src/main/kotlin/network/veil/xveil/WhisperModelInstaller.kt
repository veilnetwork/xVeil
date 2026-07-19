package network.veil.xveil

import android.content.Context
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest

/** Installs the packaged whisper model into private storage without buffering it in Dart. */
object WhisperModelInstaller {
    private const val MODEL_NAME = "ggml-base-q5_1.bin"
    private const val MODEL_SIZE = 59_707_625L
    private const val MODEL_SHA256 =
        "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"

    /**
     * Returns a filesystem path consumable by whisper.cpp, or null when a
     * development APK deliberately omitted the model. The destination lives
     * under noBackupFilesDir: the public model need not consume cloud-backup
     * quota and, unlike external storage, other apps cannot replace it.
     */
    @Synchronized
    fun ensureInstalled(context: Context): String? {
        val directory = File(context.noBackupFilesDir, "whisper")
        val destination = File(directory, MODEL_NAME)
        val marker = File(directory, "$MODEL_NAME.sha256")
        if (
            destination.isFile &&
            destination.length() == MODEL_SIZE &&
            marker.readTextOrNull()?.trim() == MODEL_SHA256
        ) {
            return destination.absolutePath
        }

        val input = try {
            context.assets.open(MODEL_NAME)
        } catch (_: FileNotFoundException) {
            // Expected only in local debug builds. Release packaging fails
            // earlier in Gradle if the source model is absent.
            return null
        }

        directory.mkdirs()
        if (!directory.isDirectory) {
            input.close()
            throw IOException("cannot create private whisper model directory")
        }
        val temporary = File(directory, "$MODEL_NAME.tmp-${android.os.Process.myPid()}")
        temporary.delete()
        marker.delete()
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var copied = 0L
            input.use { source ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                        copied += count
                    }
                    output.fd.sync()
                }
            }
            val actualSha = digest.digest().joinToString("") { "%02x".format(it) }
            if (copied != MODEL_SIZE || actualSha != MODEL_SHA256) {
                throw IOException(
                    "packaged whisper model failed integrity check " +
                        "(bytes=$copied, sha256=$actualSha)",
                )
            }

            if (destination.exists() && !destination.delete()) {
                throw IOException("cannot replace stale private whisper model")
            }
            if (!temporary.renameTo(destination)) {
                throw IOException("cannot atomically install private whisper model")
            }
            // The marker is written only after the durable atomic replacement.
            // It makes subsequent starts O(1); the original asset was verified
            // both by Gradle and again while copying.
            marker.writeText("$MODEL_SHA256\n")
            return destination.absolutePath
        } finally {
            temporary.delete()
        }
    }

    private fun File.readTextOrNull(): String? = try {
        if (isFile) readText() else null
    } catch (_: IOException) {
        null
    }
}
