package network.veil.xveil

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** A bounded stream into the document explicitly selected by the person.
 * URIs never cross into Dart and no plaintext scratch file is created.
 * All provider I/O is serialized off the UI thread; a write is acknowledged
 * only after OutputStream.write has returned, so Dart provides backpressure.
 */
class DocumentExport(owner: Activity, messenger: BinaryMessenger) {
    companion object {
        const val REQUEST_CODE = 0x5845
        const val MAX_CHUNK = 256 * 1024
    }
    private val activity = WeakReference(owner)
    private val resolver = owner.applicationContext.contentResolver
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val channel = MethodChannel(messenger, "xveil/document_export")
    private var pending: MethodChannel.Result? = null
    private var current: Session? = null
    private var working = 0
    private var disposed = false

    private class Session(val uri: Uri, var output: OutputStream?) {
        val id = UUID.randomUUID().toString()
        val aborted = AtomicBoolean(false)
        var busy = false // main-thread admission only
        var committed = false // IO executor only
        var deleted = false // IO executor only
    }

    init { channel.setMethodCallHandler(::handle) }

    private fun error(result: MethodChannel.Result, stage: String) {
        // Provider exceptions often include account-bearing URIs and paths.
        result.error("document_export_$stage", "Could not save the document.", null)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { error(result, "closed"); return }
        if (call.method == "open") {
            if (pending != null || current != null || working != 0) {
                error(result, "busy"); return
            }
            val owner = activity.get()
            val name = call.argument<Any>("name") as? String
            if (owner == null || name.isNullOrEmpty() || name.length > 200 ||
                name == "." || name == ".." ||
                name.any { it == '/' || it == '\\' || it == '\u0000' || it == '\n' || it == '\r' }) {
                error(result, "open"); return
            }
            pending = result
            try {
                owner.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, name)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }, REQUEST_CODE)
            } catch (_: Exception) { pending = null; error(result, "open") }
            return
        }
        val session = current
        if (session == null || (call.argument<Any>("id") as? String) != session.id) {
            if (call.method == "abort") result.success(null) else error(result, "closed")
            return
        }
        if (call.method == "abort") {
            session.aborted.set(true)
            current = null
            working++
            io.execute {
                val removed = discard(session)
                main.post {
                    working--
                    if (removed) result.success(null) else error(result, "abort")
                    settleDisposed()
                }
            }
            return
        }
        if (session.busy) { error(result, "busy"); return }
        val bytes = if (call.method == "write") call.argument<Any>("bytes") as? ByteArray else null
        if (call.method == "write" && (bytes == null || bytes.size > MAX_CHUNK)) {
            error(result, "chunk"); return
        }
        if (call.method != "write" && call.method != "finish") {
            result.notImplemented(); return
        }
        session.busy = true
        working++
        io.execute {
            var succeeded = false
            try {
                check(!session.aborted.get())
                val out = checkNotNull(session.output)
                if (call.method == "write") out.write(bytes!!) else {
                    out.flush()
                    out.close()
                    session.output = null
                    check(!session.aborted.get())
                    session.committed = true
                }
                succeeded = true
            } catch (_: Exception) { discard(session) }
            main.post {
                working--
                session.busy = false
                if (!succeeded || call.method == "finish") {
                    if (current === session) current = null
                }
                if (succeeded) result.success(null) else error(result, call.method)
                settleDisposed()
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        // Keep pending set while opening: another picker must not enter.
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null; result.success(null); return true
        }
        if (uri.scheme != "content") {
            pending = null; error(result, "open"); return true
        }
        working++
        io.execute {
            val session = Session(uri, null)
            var succeeded = false
            try {
                session.output = checkNotNull(resolver.openOutputStream(uri, "w"))
                succeeded = true
            } catch (_: Exception) { discard(session) }
            main.post {
                working--
                if (disposed || pending !== result) {
                    // dispose already completed the pending reply.
                    io.execute { discard(session) }
                } else {
                    pending = null
                    if (succeeded) { current = session; result.success(mapOf("id" to session.id)) }
                    else error(result, "open")
                }
                settleDisposed()
            }
        }
        return true
    }

    private fun discard(session: Session): Boolean {
        session.aborted.set(true)
        try { session.output?.close() } catch (_: Exception) { }
        session.output = null
        if (session.committed || session.deleted) return true
        return try {
            DocumentsContract.deleteDocument(resolver, session.uri).also { session.deleted = it }
        }
        catch (_: Exception) { false }
    }

    private fun settleDisposed() {
        if (disposed && working == 0) io.shutdown()
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        pending?.let { error(it, "closed") }
        pending = null
        current?.let { session ->
            session.aborted.set(true)
            io.execute { discard(session) }
        }
        current = null
        // Opening callbacks may still enqueue their disposal on the main
        // thread. Keep the executor until those operations settle; no provider
        // work or plaintext survives in app-owned files.
        settleDisposed()
    }
}
