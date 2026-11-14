package network.veil.xveil

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** No frame is persisted. The worker retains its own lease while the main
 * looper is busy, so a delayed callback cannot feed another capture. */
object ScreenCaptureBridge {
    private val main = Handler(Looper.getMainLooper())
    private val sessions = ScreenCaptureSessionGate<MethodChannel>()

    fun begin(session: String, channel: MethodChannel): Boolean = sessions.begin(session, channel)
    fun isCurrent(session: String): Boolean = sessions.current(session) != null
    fun retire(session: String, channel: MethodChannel): Boolean = sessions.end(session, channel) != null

    fun emitFrame(session: String, frame: ByteArray, completed: () -> Unit) {
        val lease = sessions.current(session)
        main.post {
            if (lease == null || !sessions.owns(lease)) {
                completed()
                return@post
            }
            lease.owner.invokeMethod("frame", mapOf("session" to session, "frame" to frame),
                object : MethodChannel.Result {
                    override fun success(result: Any?) = completed()
                    override fun error(code: String, message: String?, details: Any?) = completed()
                    override fun notImplemented() = completed()
                })
        }
    }

    fun emitStopped(session: String) {
        val lease = sessions.end(session) ?: return
        main.post { lease.owner.invokeMethod("stopped", mapOf("session" to session)) }
    }
}
